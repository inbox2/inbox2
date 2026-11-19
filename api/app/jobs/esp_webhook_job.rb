# Tells one webhook about one ESP event ("email.delivered", "email.bounced", …).
# Signing, the SSRF guard and retries are WebhookDeliveryJob's.
class EspWebhookJob < WebhookDeliveryJob
  def perform(webhook_id, event_id)
    webhook = Webhook.find_by(id: webhook_id)
    event = Esp::Event.find_by(id: event_id)
    return unless webhook&.enabled? && event

    deliver(webhook, JSON.generate(EspEventSerializer.new(event).to_h), event: event.webhook_event)
  end
end
