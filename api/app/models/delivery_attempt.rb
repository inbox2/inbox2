class DeliveryAttempt < ApplicationRecord
  key_prefix "da"

  RESULTS = %w[success transient_failure permanent_failure].freeze

  belongs_to :delivery_status
  belongs_to :delivery_channel, optional: true

  validates :attempt_number, presence: true
  validates :result, inclusion: { in: RESULTS }
end
