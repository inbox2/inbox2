class Subscription < ApplicationRecord
  key_prefix "sub"

  STATUSES = %w[active trialing past_due canceled].freeze
  STATUS_ACTIVE = "active".freeze
  STATUS_TRIALING = "trialing".freeze
  STATUS_PAST_DUE = "past_due".freeze
  STATUS_CANCELED = "canceled".freeze

  belongs_to :organization
  belongs_to :plan

  validates :status, inclusion: { in: STATUSES }

  def trial?
    status == STATUS_TRIALING && trial_ends_at&.future?
  end

  def active?
    [STATUS_ACTIVE, STATUS_TRIALING].include?(status)
  end
end
