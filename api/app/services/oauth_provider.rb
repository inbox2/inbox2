# The external mail/calendar providers inbox2 brokers OAuth for. Single source of
# truth for endpoints, scopes and credentials — shared by the stateless per-client
# proxy (Api::V1::OauthProxyController, used by the desktop/mobile clients) and
# the registered-application flow (Api::V1::AppOauthController, docs/App-OAuth.md).
module OauthProvider
  Error = Class.new(StandardError)

  GOOGLE = "google".freeze
  MICROSOFT = "microsoft".freeze
  DROPBOX = "dropbox".freeze
  # Mail and calendar providers. Dropbox is registered below for the Disk
  # importers only (docs/plans/disk-build.md 9b), so it is not in this list:
  # conferencing and the brokered app flow never offer it.
  PROVIDERS = [GOOGLE, MICROSOFT].freeze

  CONFIG = {
    GOOGLE => {
      label: "Google",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      scopes: "https://www.googleapis.com/auth/gmail.modify " \
              "https://www.googleapis.com/auth/calendar " \
              "https://www.googleapis.com/auth/contacts.readonly email profile",
      client_id_env: "GOOGLE_CLIENT_ID",
      client_secret_env: "GOOGLE_CLIENT_SECRET",
      # Google only returns a refresh token when offline access is requested.
      authorize_extra: { access_type: "offline" },
      # Google echoes the granted scope; it doesn't want one sent on the token call.
      echo_scope: false,
      userinfo_url: "https://www.googleapis.com/oauth2/v3/userinfo",
      email_fields: %w[email]
    },
    MICROSOFT => {
      label: "Microsoft 365",
      authorize_url: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      token_url: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      scopes: "Mail.ReadWrite Mail.Send Calendars.ReadWrite Contacts.Read User.Read offline_access openid",
      client_id_env: "MICROSOFT_CLIENT_ID",
      client_secret_env: "MICROSOFT_CLIENT_SECRET",
      authorize_extra: { response_mode: "query" },
      # Microsoft wants the scope repeated in the token/refresh bodies.
      echo_scope: true,
      userinfo_url: "https://graph.microsoft.com/v1.0/me",
      # A work/school account answers on `mail`; a personal one only has a UPN.
      email_fields: %w[mail userPrincipalName]
    },
    # Disk importers only; no mail scopes. Credentials come from the importer's
    # own app (Disk::ImportSource), never these env names' mail counterparts.
    DROPBOX => {
      label: "Dropbox",
      authorize_url: "https://www.dropbox.com/oauth2/authorize",
      token_url: "https://api.dropboxapi.com/oauth2/token",
      scopes: "",
      client_id_env: "DISK_IMPORT_DROPBOX_CLIENT_ID",
      client_secret_env: "DISK_IMPORT_DROPBOX_CLIENT_SECRET",
      # Dropbox issues a refresh token only for offline access.
      authorize_extra: { token_access_type: "offline" },
      echo_scope: false,
      userinfo_url: nil,
      email_fields: []
    }
  }.freeze

  module_function

  def known?(provider) = PROVIDERS.include?(provider.to_s)

  def config(provider) = CONFIG.fetch(provider.to_s) { raise(Error, "Unknown OAuth provider: #{provider}") }

  def label(provider) = config(provider)[:label]
  def authorize_url(provider) = config(provider)[:authorize_url]
  def token_url(provider) = config(provider)[:token_url]
  def scopes(provider) = config(provider)[:scopes]
  def authorize_extra(provider) = config(provider)[:authorize_extra]
  def client_id(provider) = ENV.fetch(config(provider)[:client_id_env])
  def client_secret(provider) = ENV.fetch(config(provider)[:client_secret_env])

  # The brokered application flow (docs/App-OAuth.md) redirects to an HTTPS
  # callback we host. Google only permits that on a "Web application" client, and
  # the desktop/mobile clients have to stay an installed-app client to bind
  # arbitrary loopback ports — so the broker gets its own client when one is
  # configured (GOOGLE_WEB_CLIENT_ID/_SECRET) and shares the default otherwise.
  # Microsoft needs no split: one registration carries both platforms.
  def web_client_id(provider) = ENV["#{provider.to_s.upcase}_WEB_CLIENT_ID"].presence || client_id(provider)
  def web_client_secret(provider) = ENV["#{provider.to_s.upcase}_WEB_CLIENT_SECRET"].presence || client_secret(provider)

  # Params the provider wants echoed on the token + refresh calls. `scope`
  # overrides the default mail scopes for narrower grants (e.g. conferencing).
  def token_extra(provider, scope: nil) = config(provider)[:echo_scope] ? { scope: scope || scopes(provider) } : {}

  # The provider's consent URL for a full authorization-code flow. Used only by
  # the brokered application flow, hence the web client.
  # `client` ({ id:, secret:, authorize_url:, token_url: }) overrides the
  # provider's default web client and endpoints, for grants made by a separate
  # app registration (the Disk importers, Disk::ImportSource.client).
  def authorize_uri(provider, redirect_uri:, state:, login_hint: nil, scope: nil, client: nil)
    query = {
      client_id: client ? client[:id] : web_client_id(provider),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: scope || scopes(provider),
      state: state
    }.merge(authorize_extra(provider))
    # Dropbox has no prompt parameter; it always shows its consent screen.
    query[:prompt] = "consent" unless provider.to_s == DROPBOX
    query[:login_hint] = login_hint if login_hint.present?
    "#{client&.dig(:authorize_url) || authorize_url(provider)}?#{query.to_query}"
  end

  # Trade an authorization code for tokens. Returns the provider's parsed JSON
  # ({ access_token, refresh_token, expires_in, scope, … }) or raises Error — the
  # caller is a browser redirect, so there's no upstream body to pass through.
  def exchange_code(provider, code, redirect_uri, scope: nil, client: nil)
    response = post_form(client&.dig(:token_url) || token_url(provider), {
      code: code,
      client_id: client ? client[:id] : web_client_id(provider),
      client_secret: client ? client[:secret] : web_client_secret(provider),
      redirect_uri: redirect_uri,
      grant_type: "authorization_code"
    }.merge(token_extra(provider, scope: scope)))

    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "#{label(provider)} token exchange failed: HTTP #{response.code} #{response.body}"
    end

    JSON.parse(response.body)
  end

  # Refresh an access token minted by the brokered flow. It has to run against
  # the same (web) client that issued the refresh token — the per-client proxy's
  # refresh endpoint uses the installed-app client and would be rejected.
  def refresh_tokens(provider, refresh_token, scope: nil, client: nil)
    response = post_form(client&.dig(:token_url) || token_url(provider), {
      refresh_token: refresh_token,
      client_id: client ? client[:id] : web_client_id(provider),
      client_secret: client ? client[:secret] : web_client_secret(provider),
      grant_type: "refresh_token"
    }.merge(token_extra(provider, scope: scope)))

    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "#{label(provider)} token refresh failed: HTTP #{response.code} #{response.body}"
    end

    JSON.parse(response.body)
  end

  # The mailbox the user just consented with, so the calling app knows which
  # account it received. Best-effort: a missing userinfo response is not worth
  # failing an otherwise-complete authorization over.
  # url overrides the provider's userinfo endpoint (the Disk importers' test endpoints).
  def fetch_email(provider, access_token, url: nil)
    uri = URI(url || config(provider)[:userinfo_url])
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    response = http_for(uri).request(request)
    return nil unless response.is_a?(Net::HTTPSuccess)

    json = JSON.parse(response.body)
    config(provider)[:email_fields].filter_map { |field| json[field].presence }.first
  rescue StandardError => e
    Rails.logger.warn("[oauth] #{label(provider)} userinfo lookup failed: #{e.class}: #{e.message}")
    nil
  end

  def post_form(url, form_data)
    uri = URI(url)
    request = Net::HTTP::Post.new(uri.path)
    request.set_form_data(form_data)
    http_for(uri).request(request)
  end

  def http_for(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http
  end
end
