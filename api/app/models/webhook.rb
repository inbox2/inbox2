class Webhook < ApplicationRecord
  key_prefix "whk"

  # ESP delivery events (docs/ESP.md): "email." + the status a delivery moved to.
  EMAIL_EVENT_PREFIX = "email.".freeze
  EMAIL_EVENTS = %w[delivered deferred bounced failed complained].map { |s| "#{EMAIL_EVENT_PREFIX}#{s}" }.freeze
  EVENTS = (%w[message.created conversation.updated conversation.assigned conversation.tagged rule.matched] + EMAIL_EVENTS).freeze
  EVENT_MESSAGE_CREATED = "message.created".freeze
  EVENT_CONVERSATION_UPDATED = "conversation.updated".freeze
  EVENT_CONVERSATION_ASSIGNED = "conversation.assigned".freeze
  EVENT_CONVERSATION_TAGGED = "conversation.tagged".freeze
  EVENT_RULE_MATCHED = "rule.matched".freeze

  belongs_to :organization

  validates :url, presence: true
  validate :events_valid

  private

  def events_valid
    return if events.blank?

    invalid = events - EVENTS
    errors.add(:events, "contains invalid events: #{invalid.join(', ')}") if invalid.any?
  end
end
