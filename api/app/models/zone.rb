# A calendar zone (docs/Calendar.md "Zones"): a soft block the member wants to
# spend on one thing. People can still book the time, unless `blocks` is on —
# then FreeBusy reads it as busy, exactly like blocked time. Clients draw it behind events and
# raise a sticky "you're in the zone" card at `start_at` when `notify` is on.
#
# A repeating zone is one row; `occurrences` expands it on read, in the zone's
# own time zone, so "weekdays 16:00" stays 16:00 across a DST change.
class Zone < ApplicationRecord
  key_prefix "zon"

  REPEAT_NONE = "none"
  REPEAT_DAILY = "daily"
  REPEAT_WEEKDAYS = "weekdays"
  REPEAT_WEEKLY = "weekly"
  REPEATS = [REPEAT_NONE, REPEAT_DAILY, REPEAT_WEEKDAYS, REPEAT_WEEKLY].freeze

  # Longest single zone; also bounds how far back an occurrence can start and
  # still overlap the window being read.
  MAX_LENGTH = 24.hours

  # One zone expanded for a window: the series row plus this occurrence's times.
  Occurrence = Struct.new(:zone, :start_at, :end_at) do
    # "zon_x@20260925T140000Z" — the calendar's occurrence-id scheme. A single
    # zone keeps its bare key.
    def id
      zone.repeating? ? "#{zone.key}@#{start_at.utc.strftime('%Y%m%dT%H%M%SZ')}" : zone.key
    end
  end

  belongs_to :user
  belongs_to :zone_category, optional: true

  validates :name, presence: true, length: { maximum: 120 }
  validates :start_at, presence: true
  validates :end_at, presence: true
  validates :repeat, inclusion: { in: REPEATS }
  validates :anchor_minutes, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :end_after_start
  validate :category_is_own
  validate :known_time_zone

  # Candidates for a window: singles that overlap it, plus every repeating
  # series that has started by its end and hasn't run out before its start.
  scope :touching, ->(range_start, range_end) {
    where(repeat: REPEAT_NONE).where("start_at < ? AND end_at > ?", range_end, range_start)
      .or(where.not(repeat: REPEAT_NONE).where("start_at < ?", range_end)
        .where("repeat_until IS NULL OR repeat_until >= ?", (range_start - MAX_LENGTH).to_date))
  }

  def repeating?
    repeat != REPEAT_NONE
  end

  def zone_time_zone
    ActiveSupport::TimeZone[time_zone.to_s] || ActiveSupport::TimeZone[user&.default_timezone.to_s] || ActiveSupport::TimeZone["UTC"]
  end

  # The occurrences that overlap [range_start, range_end).
  def occurrences(range_start, range_end)
    length = end_at - start_at
    unless repeating?
      return start_at < range_end && end_at > range_start ? [Occurrence.new(self, start_at, end_at)] : []
    end

    tz = zone_time_zone
    first = start_at.in_time_zone(tz)
    # Each occurrence ends at the series' wall-clock end, not start + the first
    # one's elapsed length: a zone made on a DST change day would otherwise run
    # an hour short (or long) every other day.
    finish = end_at.in_time_zone(tz)
    span_days = (finish.to_date - first.to_date).to_i
    # One extra day back: a wall-clock end can make an occurrence up to an hour
    # longer than `length` across a clock change; the overlap check below trims.
    day = [first.to_date, (range_start - length).in_time_zone(tz).to_date - 1].max
    last = range_end.in_time_zone(tz).to_date
    last = [last, repeat_until].min if repeat_until

    out = []
    skipped = skip_dates.to_set
    while day <= last
      if repeats_on?(day, first) && !skipped.include?(day)
        if day == first.to_date
          # The stored occurrence is exact; rebuilding it from wall clocks can pick
          # the wrong side of an ambiguous autumn hour.
          s, e = start_at, end_at
        else
          s = tz.local(day.year, day.month, day.day, first.hour, first.min, first.sec, first.usec)
          end_day = day + span_days
          e = tz.local(end_day.year, end_day.month, end_day.day, finish.hour, finish.min, finish.sec, finish.usec)
          e = s + length if e <= s
        end
        out << Occurrence.new(self, s, e) if s >= start_at && s < range_end && e > range_start
      end
      day += 1
    end
    out
  end

  # Drops the occurrence starting at `occurrence_start` from the series; the
  # rest of the series stays.
  def skip_occurrence(occurrence_start)
    day = occurrence_start.in_time_zone(zone_time_zone).to_date
    # with_lock reloads first, so two skips at once can't drop each other's day.
    with_lock { update!(skip_dates: (skip_dates | [day]).sort) }
  end

  # Moving one occurrence moves the series the same way, so an edit made on any
  # day of a weekly zone changes it everywhere. Done in wall-clock terms in the
  # zone's time zone — whole days plus the new local time — so a retime across
  # a DST change keeps 16:00 at 16:00 rather than drifting an hour.
  def shift_from_occurrence(occurrence_start, new_start, new_end)
    tz = zone_time_zone
    days = (new_start.in_time_zone(tz).to_date - occurrence_start.in_time_zone(tz).to_date).to_i
    day = start_at.in_time_zone(tz).to_date + days
    local = new_start.in_time_zone(tz)
    self.start_at = tz.local(day.year, day.month, day.day, local.hour, local.min)
    self.end_at = start_at + (new_end - new_start)
  end

  private

  def repeats_on?(day, first)
    case repeat
    when REPEAT_DAILY then true
    when REPEAT_WEEKDAYS then (1..5).cover?(day.wday)
    when REPEAT_WEEKLY then day.wday == first.wday
    else false
    end
  end

  def end_after_start
    return if start_at.blank? || end_at.blank?
    return errors.add(:end_at, "must be after start") unless end_at > start_at

    errors.add(:end_at, "must be within 24 hours of the start") if end_at - start_at > MAX_LENGTH
  end

  def category_is_own
    return if zone_category.nil? || zone_category.user_id == user_id

    errors.add(:zone_category, "not found")
  end

  def known_time_zone
    return if time_zone.blank? || ActiveSupport::TimeZone[time_zone]

    errors.add(:time_zone, "is not a known time zone")
  end
end
