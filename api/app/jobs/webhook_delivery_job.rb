require "net/http"
require "uri"
require "ipaddr"
require "resolv"

# Delivers a `rule.matched` event to a user-configured webhook endpoint (spec
# 7.3.5). Async + retried so a slow/flaky endpoint never blocks mail ingest.
#
# Security:
#   - Signs the body with HMAC-SHA256 under the webhook's secret
#     (`X-Inbox2-Signature: sha256=…`) so receivers can verify authenticity.
#   - SSRF guard: refuses to POST to loopback/private/link-local addresses in
#     production (webhooks are admin-configured, but this blocks pivoting to
#     internal services). Allowed in dev/test so local endpoints can be exercised.
class WebhookDeliveryJob < ApplicationJob
  queue_as :default

  class DeliveryError < StandardError; end
  class BlockedTargetError < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # Retry only on transient failures (timeouts, 5xx, 429). 4xx (except 429) and a
  # blocked target are terminal — retrying won't help.
  retry_on DeliveryError, wait: :polynomially_longer, attempts: 5
  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 5
  discard_on BlockedTargetError

  def perform(webhook_id, conversation_id, message_id, rule_id)
    webhook = Webhook.find_by(id: webhook_id)
    return unless webhook&.enabled?

    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation

    message = message_id && Message.find_by(id: message_id)
    rule = rule_id && Rule.find_by(id: rule_id)

    body = WebhookPayloadBuilder.new(webhook, conversation, message, rule).to_json
    deliver(webhook, body)
  end

  private

  def deliver(webhook, body, event: Webhook::EVENT_RULE_MATCHED)
    uri = URI.parse(webhook.url)
    raise BlockedTargetError, "unsupported scheme #{uri.scheme}" unless %w[http https].include?(uri.scheme)
    pinned_ip = guard_target!(uri)

    http = Net::HTTP.new(uri.host, uri.port)
    # Connect to the address the guard validated; Host/SNI stay the hostname.
    # Resolving again at connect time would reopen the DNS-rebinding window.
    http.ipaddr = pinned_ip if pinned_ip
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request["User-Agent"] = "inbox2-webhooks/1"
    request["X-Inbox2-Event"] = event
    if webhook.secret.present?
      sig = OpenSSL::HMAC.hexdigest("SHA256", webhook.secret, body)
      request["X-Inbox2-Signature"] = "sha256=#{sig}"
    end
    request.body = body

    response = http.request(request)
    code = response.code.to_i
    # 5xx and 429 are transient → retry; other non-2xx are terminal (logged, dropped).
    raise DeliveryError, "endpoint returned #{code}" if code >= 500 || code == 429
    unless (200..299).cover?(code)
      Rails.logger.warn("[WebhookDeliveryJob] #{webhook.key} → #{uri.host} returned #{code} (dropping)")
    end
  end

  # Same SSRF rule as the image proxy and the strip feeds (PrivateAddressGuard):
  # every resolved address must be public, and the connection is pinned to one
  # of them. Returns the pinned IP, or nil in dev/test where webhooks legitimately
  # point at localhost.
  def guard_target!(uri)
    return nil if Rails.env.development? || Rails.env.test?

    ip = PrivateAddressGuard.pinned_public_ip(uri.host)
    raise BlockedTargetError, "blocked or unresolvable webhook target #{uri.host}" unless ip

    ip
  end
end
