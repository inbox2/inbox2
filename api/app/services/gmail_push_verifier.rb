# Verifies inbound Gmail Pub/Sub push requests (TODO 45.6). Two independent
# layers, each enforced when configured:
#
#   1. Shared verification token appended to the push subscription URL
#      (?token=...) — GMAIL_PUBSUB_VERIFICATION_TOKEN. Cheap first gate.
#   2. The OIDC bearer JWT Cloud Pub/Sub attaches when the subscription has an
#      oidc_token block (see deploy/gcp-pubsub). Verified via googleauth's
#      Google::Auth::IDTokens — Google JWKS signature, expiry, iss, aud (our
#      webhook URL) — plus the service-account email claim.
#      GMAIL_PUBSUB_SERVICE_ACCOUNT names the expected SA.
#
# When neither is configured (dev/test), requests are accepted — the dev path
# is a Tailscale Funnel tunnel, not the public internet.
class GmailPushVerifier
  def self.verify(request)
    token_ok?(request) && oidc_ok?(request)
  end

  def self.token_ok?(request)
    expected = PushConfig.gmail_verification_token
    return true if expected.nil?

    provided = request.query_parameters["token"] || request.params["token"]
    provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided.to_s, expected)
  end

  def self.oidc_ok?(request)
    expected_sa = PushConfig.gmail_push_service_account
    return true if expected_sa.nil?

    bearer = request.headers["Authorization"].to_s[/\ABearer (.+)\z/, 1]
    return false if bearer.blank?

    # verify_oidc fetches + caches Google's JWKS and checks signature, expiry,
    # issuer, and audience.
    payload = Google::Auth::IDTokens.verify_oidc(bearer, aud: PushConfig.gmail_push_audience)
    payload["email"] == expected_sa && payload["email_verified"] == true
  rescue Google::Auth::IDTokens::VerificationError => e
    Rails.logger.warn("[GmailPushVerifier] OIDC verification failed: #{e.message}")
    false
  end
end
