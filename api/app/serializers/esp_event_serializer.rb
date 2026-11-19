# Also the webhook body for "email.<kind>" events.
class EspEventSerializer < ApplicationSerializer
  attributes :detail, :created_at

  attribute(:type) { |e| e.webhook_event }
  attribute(:email_id) { |e| e.message.key }
  attribute(:recipient) { |e| e.delivery.recipient }
  attribute(:tag) { |e| e.message.tag }
  attribute(:metadata) { |e| e.message.metadata }
end
