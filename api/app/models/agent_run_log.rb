class AgentRunLog < ApplicationRecord
  key_prefix "arl"

  STATUSES = %w[success failure rate_limited].freeze
  STATUS_SUCCESS = "success".freeze
  STATUS_FAILURE = "failure".freeze
  STATUS_RATE_LIMITED = "rate_limited".freeze

  ACTIONS = %w[reply tag set_status assign grant_access read].freeze

  belongs_to :agent
  belongs_to :conversation, optional: true

  validates :action, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }
end
