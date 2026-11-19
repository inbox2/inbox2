# One zone occurrence's start card, clicked away (docs/Calendar.md "Zones").
# Server-side so "Done" on the desktop clears the card on the phone too.
# `occurrence_id` is the zone list's `id` (series key, or "zon_x@…Z").
class ZoneDismissal < ApplicationRecord
  # Kept this long past the zone's end, then swept on the next write.
  RETENTION = 7.days

  belongs_to :user

  validates :occurrence_id, presence: true, length: { maximum: 64 }
  validates :end_at, presence: true

  scope :live, -> { where("end_at > ?", Time.current - 1.day) }

  def series_key
    occurrence_id.split("@").first
  end
end
