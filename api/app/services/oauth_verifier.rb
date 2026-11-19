require "net/http"
require "json"
require "base64"
require "cgi"

# Verifies an OAuth access token directly with the provider and returns the
# provider-asserted identity. The web SSO callback must NOT trust client-supplied
# uid/email — anyone can POST those. Only an identity derived from a token the
# provider itself issued (and that we re-check against the provider) is trusted.
#
# Crucially, we also verify the token's AUDIENCE — that it was minted for *our*
# OAuth client, not just for some valid Google/Microsoft app. Without this, the
# provider userinfo endpoints happily accept any valid token, so an attacker
# running their own OAuth app could replay a victim's token for that app and log
# in as the victim here (confused-deputy account takeover).
class OauthVerifier
  USERINFO_URLS = {
    OauthIdentity::PROVIDER_GOOGLE => "https://openidconnect.googleapis.com/v1/userinfo",
    OauthIdentity::PROVIDER_MICROSOFT => "https://graph.microsoft.com/v1.0/me"
  }.freeze

  GOOGLE_TOKENINFO_URL = "https://oauth2.googleapis.com/tokeninfo".freeze

  Identity = Struct.new(:uid, :email, :name, keyword_init: true)

  # Returns an Identity (uid required) or nil if the token can't be verified or
  # wasn't issued to our OAuth client.
  def self.verify(provider, access_token)
    url = USERINFO_URLS[provider]
    return nil if url.blank? || access_token.blank?

    # Reject tokens not minted for our client BEFORE trusting any identity claim.
    return nil unless audience_ok?(provider, access_token)

    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    response = http.request(request)
    return nil unless response.is_a?(Net::HTTPSuccess)

    identity = extract(provider, JSON.parse(response.body))
    identity if identity&.uid.present?
  rescue StandardError => e
    Rails.logger.warn("[OauthVerifier] #{provider} verification failed: #{e.class}: #{e.message}")
    nil
  end

  # True only when the access token's audience/authorized-party is our own client
  # for the provider. Google: ask the tokeninfo endpoint and match aud/azp.
  # Microsoft: Graph tokens are JWTs carrying appid/azp = the requesting client.
  def self.audience_ok?(provider, access_token)
    case provider
    when OauthIdentity::PROVIDER_GOOGLE
      expected = ENV["GOOGLE_CLIENT_ID"]
      return client_id_unconfigured(provider) if expected.blank?

      info = google_tokeninfo(access_token)
      return false unless info

      [info["aud"], info["azp"]].compact.include?(expected)
    when OauthIdentity::PROVIDER_MICROSOFT
      expected = ENV["MICROSOFT_CLIENT_ID"]
      return client_id_unconfigured(provider) if expected.blank?

      claims = decode_jwt_claims(access_token)
      return false unless claims

      [claims["appid"], claims["azp"]].compact.include?(expected)
    else
      false
    end
  end

  # Fail CLOSED in production when the client id isn't configured (we can't prove
  # audience); allow in dev/test so the flow is testable without real OAuth creds.
  def self.client_id_unconfigured(provider)
    if Rails.env.production?
      Rails.logger.error("[OauthVerifier] #{provider} client_id not configured — refusing token (fail closed)")
      false
    else
      Rails.logger.warn("[OauthVerifier] #{provider} client_id not configured — skipping audience check (non-production)")
      true
    end
  end

  def self.google_tokeninfo(access_token)
    uri = URI(GOOGLE_TOKENINFO_URL)
    uri.query = URI.encode_www_form(access_token: access_token)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5

    response = http.request(Net::HTTP::Get.new(uri))
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue StandardError => e
    Rails.logger.warn("[OauthVerifier] google tokeninfo failed: #{e.class}: #{e.message}")
    nil
  end

  # Decode (without signature verification — we only read the audience claim, and
  # the identity itself is still re-fetched from the provider) a JWT's payload.
  def self.decode_jwt_claims(jwt)
    payload = jwt.to_s.split(".")[1]
    return nil if payload.blank?

    json = Base64.urlsafe_decode64(payload + ("=" * (-payload.length % 4)))
    JSON.parse(json)
  rescue StandardError
    nil
  end

  def self.extract(provider, data)
    case provider
    when OauthIdentity::PROVIDER_GOOGLE
      verified = data["email_verified"] == true || data["email_verified"].to_s == "true"
      Identity.new(uid: data["sub"], email: (data["email"] if verified), name: data["name"])
    when OauthIdentity::PROVIDER_MICROSOFT
      Identity.new(uid: data["id"], email: data["mail"].presence || data["userPrincipalName"], name: data["displayName"])
    end
  end
end
