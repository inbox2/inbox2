class RuleLog < ApplicationRecord
  key_prefix "rl"

  belongs_to :rule
  belongs_to :conversation

  scope :recent, -> { order(created_at: :desc) }
end
