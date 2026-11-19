class ActivityEvent < ApplicationRecord
  key_prefix "evt"

  # Member-attributable actions surfaced on the Team activity board. Referenced
  # everywhere instead of raw strings (see conversations_controller#snooze etc.).
  ACTION_REPLIED  = "replied".freeze
  ACTION_DELETED  = "deleted".freeze
  ACTION_ARCHIVED = "archived".freeze
  ACTION_READ     = "read".freeze
  ACTION_SNOOZED  = "snoozed".freeze
  ACTION_ASSIGNED = "assigned".freeze
  METRIC_ACTIONS = [ACTION_REPLIED, ACTION_DELETED, ACTION_ARCHIVED, ACTION_READ, ACTION_SNOOZED, ACTION_ASSIGNED].freeze

  belongs_to :conversation
  belongs_to :organization
  belongs_to :membership, optional: true

  validates :action, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def self.log(conversation:, action:, membership: nil, metadata: {})
    create!(
      conversation: conversation,
      organization: conversation.organization,
      membership: membership,
      action: action,
      metadata: metadata
    )
  end
end
