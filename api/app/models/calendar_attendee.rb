class CalendarAttendee < ApplicationRecord
  key_prefix "cat"

  RESPONSE_STATUSES = %w[needs_action accepted declined tentative].freeze
  RESPONSE_NEEDS_ACTION = "needs_action".freeze
  RESPONSE_ACCEPTED = "accepted".freeze
  RESPONSE_DECLINED = "declined".freeze
  RESPONSE_TENTATIVE = "tentative".freeze

  belongs_to :calendar_event

  validates :email, presence: true, uniqueness: { scope: :calendar_event_id }
  validates :response_status, inclusion: { in: RESPONSE_STATUSES }
end
