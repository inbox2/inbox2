module Api
  module V1
    # Provider OAuth brokered on behalf of a registered application
    # (docs/App-OAuth.md). inbox2 owns the Google / Microsoft client credentials;
    # a registered app borrows them and receives the resulting mailbox tokens.
    #
    #   authorize — the app's SERVER, with an inbox2 API key. Opens a flow and
    #               returns the consent URL to send the user to.
    #   consent   — the consent PAGE (public). App name/icon + which provider.
    #   start     — Continue on the consent page (public). 302 to the provider.
    #   callback  — the PROVIDER's redirect (public). Exchanges the code and
    #               bounces the user to the app's whitelisted redirect URL.
    #   token     — the app's SERVER again, with its API key. Redeems the tokens
    #               once; the grant is emptied on read.
    class AppOauthController < BaseController
      PUBLIC_ACTIONS = %i[consent start callback cancel].freeze

      # The browser-facing legs carry no inbox2 credentials at all: the person
      # granting access to their Google/Microsoft mailbox is not (necessarily) an
      # inbox2 user. The flow's unguessable key is the only handle, and it buys
      # nothing without the app's API key at redemption.
      skip_before_action :authenticate_user!, only: PUBLIC_ACTIONS
      skip_before_action :enforce_api_key_scope!, only: PUBLIC_ACTIONS

      # POST /api/v1/auth/app-oauth/authorize
      # Params: app (oap_… or the registered name), provider (google|microsoft),
      #         redirect_uri (must be whitelisted on the app), state (optional).
      def authorize
        app = OauthApp.resolve(OauthApp.where(organization: current_user.accessible_organizations),
                               params.require(:app))
        return render_error("Unknown application", :not_found) unless app

        provider = params.require(:provider).to_s.downcase
        return render_error("Unsupported provider: #{provider}", :unprocessable_content) unless OauthProvider.known?(provider)

        redirect_uri = params.require(:redirect_uri).to_s
        unless app.allows_redirect?(redirect_uri)
          return render_error("redirect_uri is not registered for this application", :unprocessable_content)
        end

        grant = app.oauth_grants.create!(
          provider: provider,
          redirect_uri: redirect_uri,
          client_state: params[:state].presence
        )

        render json: {
          flow: grant.key,
          authorize_url: "#{web_base}/oauth/consent?flow=#{grant.key}",
          expires_at: grant.expires_at
        }, status: :created
      end

      # GET /api/v1/auth/app-oauth/consent?flow= — public. Everything the consent
      # screen renders: who is asking, and which provider they want.
      def consent
        grant = pending_grant
        return render_error("This link has expired — start again from the app", :not_found) unless grant

        render json: {
          app: OauthAppSerializer.new(grant.oauth_app).to_h,
          provider: grant.provider,
          provider_label: grant.provider_label,
          expires_at: grant.expires_at
        }
      end

      # GET /api/v1/auth/app-oauth/start?flow= — public. The consent screen's
      # Continue button; a plain navigation, so the redirect is server-side.
      def start
        grant = pending_grant
        return render_error("This link has expired — start again from the app", :not_found) unless grant

        grant.update!(callback_uri: callback_url)
        redirect_to OauthProvider.authorize_uri(grant.provider, redirect_uri: callback_url, state: grant.key),
                    allow_other_host: true
      end

      # GET /api/v1/auth/app-oauth/cancel?flow= — public. "Not now" on the consent
      # screen: the user goes back to the app with an explicit denial rather than
      # a dead tab.
      def cancel
        grant = pending_grant
        return render_error("This link has expired", :not_found) unless grant

        redirect_to grant.return_uri(error: "access_denied"), allow_other_host: true
      end

      # GET /api/v1/auth/app-oauth/callback?code=&state= — the provider's redirect.
      def callback
        grant = OauthGrant.find_by(key: params[:state])
        return render_error("Unknown or expired authorization", :bad_request) unless grant&.pending?

        if params[:error].present?
          return redirect_to grant.return_uri(error: params[:error]), allow_other_host: true
        end

        # `start` recorded the exact redirect_uri handed to the provider — the
        # token exchange has to replay the same string or the provider rejects it.
        tokens = OauthProvider.exchange_code(grant.provider, params.require(:code), grant.callback_uri)
        grant.authorize!(tokens, OauthProvider.fetch_email(grant.provider, tokens["access_token"]))

        redirect_to grant.return_uri(flow: grant.key), allow_other_host: true
      rescue OauthProvider::Error => e
        Rails.logger.warn("[app-oauth] #{e.message}")
        redirect_to grant.return_uri(error: "server_error"), allow_other_host: true
      end

      # POST /api/v1/auth/app-oauth/token — the app's server redeems the provider
      # tokens with its inbox2 API key. Single use: the grant is emptied on read.
      def token
        grant = OauthGrant.find_by(key: params.require(:flow))
        unless grant && current_user.accessible_organizations.exists?(id: grant.oauth_app.organization_id)
          return render_error("Unknown authorization", :not_found)
        end
        return render_error("Authorization is not ready or has already been used", :bad_request) unless grant.redeemable?

        render json: { credential: grant.redeem! }
      end

      # POST /api/v1/auth/app-oauth/refresh — the app's server trades an expiring
      # access token for a fresh one. Its own endpoint rather than the per-client
      # proxy's: a token minted by the brokered flow belongs to the web client,
      # and the proxy refreshes against the installed-app client.
      def refresh
        provider = params.require(:provider).to_s.downcase
        return render_error("Unsupported provider: #{provider}", :unprocessable_content) unless OauthProvider.known?(provider)

        render json: OauthProvider.refresh_tokens(provider, params.require(:refresh_token))
      rescue OauthProvider::Error => e
        Rails.logger.warn("[app-oauth] #{e.message}")
        render_error("Token refresh was rejected by the provider", :bad_request)
      end

      private

      def pending_grant
        grant = OauthGrant.find_by(key: params[:flow])
        grant if grant&.pending?
      end

      def render_error(message, status)
        render json: ErrorSerializer.serialize(message, status: Rack::Utils.status_code(status)), status: status
      end

      # Must exactly match a redirect URI registered on the inbox2 Google Cloud
      # project / Azure app registration. Derived from the serving host so dev and
      # prod each work with their own registration; override when the API is
      # reached on a different public name than the one Rails sees.
      def callback_url
        ENV.fetch("OAUTH_APP_CALLBACK_URL", "#{request.base_url}/api/v1/auth/app-oauth/callback")
      end

      def web_base
        ENV.fetch("WEB_APP_URL", "https://app.inbox2.com").chomp("/")
      end
    end
  end
end
