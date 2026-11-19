class CalendarReminder < ApplicationRecord
  key_prefix "crm"

  METHODS = %w[popup email].freeze

  belongs_to :calendar_event

  validates :minutes_before, presence: true, numericality: { greater_than: 0 }
  validates :method, inclusion: { in: METHODS }
end
