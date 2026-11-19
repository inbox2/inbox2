# Public .well-known endpoints (no auth — verifiers fetch these anonymously).
#
# The HTTP Message Signatures key directory advertises the image proxy's Ed25519
# public key for Cloudflare's Verified Bots program (Web Bot Auth): a verifier
# resolves the Signature-Agent URL on a signed fetch to this JWKS and checks the
# request signature against it. The response is itself signed (tag
# "http-message-signatures-directory") to prove key possession, and is served as
# raw JSON with the draft's dedicated content type — a deliberate exception to
# E2/Alba, like the image proxy's raw bytes.
class WellKnownController < ApplicationController
  def http_message_signatures_directory
    return head :not_found unless WebBotAuth.enabled?

    WebBotAuth.directory_headers(authority: WebBotAuth.authority_for(request)).each do |name, value|
      response.set_header(name, value)
    end
    expires_in 1.day, public: true
    render json: { keys: [WebBotAuth.public_jwk] }, content_type: WebBotAuth::DIRECTORY_CONTENT_TYPE
  end

  # Serves the MTA-STS policy file for the domain in the request Host
  # (mta-sts.<domain>). Only "testing"/"enforce" policies are advertised; a
  # missing or "none" policy 404s so senders treat the domain as no-policy.
  def mta_sts
    domain = request.host.to_s.sub(/\Amta-sts\./i, "").downcase
    policy = Domain.find_by(name: domain)&.mta_sts_policy

    return head :not_found if policy.nil? || policy.mode == MtaStsPolicy::MODE_NONE

    expires_in 1.day, public: true
    render plain: policy.policy_text, content_type: "text/plain"
  end
end
