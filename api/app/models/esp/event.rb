# Something that happened to one delivery. The kind is the status the delivery
# moved to; an org's webhooks subscribed to "email.<kind>" are told.
class Esp::Event < ApplicationRecord
  key_prefix "ev"

  belongs_to :organization
  belongs_to :message, class_name: "Esp::Message", foreign_key: :esp_message_id, inverse_of: :events
  belongs_to :delivery, class_name: "Esp::Delivery", foreign_key: :esp_delivery_id, inverse_of: :events

  validates :kind, inclusion: { in: Esp::Delivery::STATUSES }

  after_create_commit :notify_webhooks

  def webhook_event = "#{Webhook::EMAIL_EVENT_PREFIX}#{kind}"

  private

  def notify_webhooks
    organization.webhooks.where(enabled: true).select { |w| Array(w.events).include?(webhook_event) }.each do |webhook|
      EspWebhookJob.perform_later(webhook.id, id)
    end
  end
end
