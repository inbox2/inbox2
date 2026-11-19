require "net/http"
require "json"

# Server-side verification for Cloudflare Turnstile tokens (the waitlist form's
# bot gate). When TURNSTILE_SECRET is unset the verifier is a no-op that passes
# in dev/test — so local work needs no Cloudflare key — but FAILS CLOSED in
# production: a missing secret there is a deployment mistake, not a choice, and
# it used to turn the public waitlist into an open form without a log line.
class TurnstileVerifier
  VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze

  def self.configured?
    ENV["TURNSTILE_SECRET"].present?
  end

  # @return [Boolean] true when the challenge passes (or enforcement is disabled).
  def self.verify(token, remote_ip: nil)
    unless configured?
      return true unless Rails.env.production?

      Rails.logger.error("[Turnstile] TURNSTILE_SECRET is unset in production — refusing the challenge")
      return false
    end
    return false if token.blank?

    uri = URI(VERIFY_URL)
    params = { secret: ENV.fetch("TURNSTILE_SECRET"), response: token }
    params[:remoteip] = remote_ip if remote_ip.present?

    response = Net::HTTP.post_form(uri, params)
    body = JSON.parse(response.body)
    body["success"] == true
  rescue StandardError => e
    Rails.logger.warn("[Turnstile] verification error: #{e.class}: #{e.message}")
    false
  end
end
