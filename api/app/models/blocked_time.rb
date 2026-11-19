# A "not available" window (docs/Calendar.md): feeds free/busy as plain busy —
# for meet-link visitors and colleagues alike — but is deliberately NOT a
# calendar event. Only the owner sees it, hatched, in their own calendar.
class BlockedTime < ApplicationRecord
  key_prefix "blk"

  belongs_to :organization
  belongs_to :membership

  validates :start_at, presence: true
  validates :end_at, presence: true
  validate :end_after_start

  scope :in_range, ->(range_start, range_end) {
    where("start_at < ? AND end_at > ?", range_end, range_start)
  }

  private

  def end_after_start
    return if start_at.blank? || end_at.blank? || end_at > start_at

    errors.add(:end_at, "must be after start")
  end
end
