class CalendarEvent < ApplicationRecord
  key_prefix "cev"

  STATUSES = %w[confirmed tentative cancelled].freeze
  STATUS_CONFIRMED = "confirmed".freeze
  STATUS_TENTATIVE = "tentative".freeze
  STATUS_CANCELLED = "cancelled".freeze

  VISIBILITIES = %w[default public private].freeze

  # Safety valve when a pathological RRULE (e.g. SECONDLY with no UNTIL) meets a
  # wide range — expansion is per-request work, so it stays bounded.
  MAX_OCCURRENCES = 1000

  # Separates the series key from the occurrence start in a virtual occurrence
  # id ("cev_abc@20260101T090000Z"). Nanoid keys never contain "@", so the split
  # is unambiguous. Mirrors how Google Calendar addresses a single instance.
  OCCURRENCE_SEPARATOR = "@".freeze

  belongs_to :calendar
  belongs_to :organization
  belongs_to :created_by_membership, class_name: "Membership", optional: true
  has_many :attendees, class_name: "CalendarAttendee", dependent: :destroy
  has_many :reminders, class_name: "CalendarReminder", dependent: :destroy
  # An accepted meet-link request pointing here; nullify so deleting the event
  # (or cancelling the series) never trips the FK.
  has_one :meeting_request, dependent: :nullify

  before_validation :default_title
  after_create :assign_ical_uid

  validates :title, presence: true
  validates :start_at, presence: true
  validates :end_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :visibility, inclusion: { in: VISIBILITIES }
  validate :end_after_start

  scope :in_range, ->(range_start, range_end) {
    where("start_at < ? AND end_at > ?", range_end, range_start)
  }
  scope :not_cancelled, -> { where.not(status: STATUS_CANCELLED) }

  # Everything a member may READ: events on calendars they own or that are
  # org-shared, PLUS every event they were invited to.
  #
  # That second half is what makes an internal invitation work like Google
  # Workspace: the meeting appears on a colleague's calendar the moment they are
  # added, with no copy of the row. One canonical event means the organizer sees
  # responses live, updates can't drift between copies, and cancelling really
  # cancels. Being invited grants read + RSVP only — see `editable_by`.
  scope :visible_to, ->(membership) {
    calendars = membership.organization.calendars.for_member(membership)
    addresses = membership.email_addresses.map(&:downcase)
    owned = where(calendar_id: calendars)
    next owned if addresses.empty?

    invited = where(id: CalendarAttendee.where("LOWER(email) IN (?)", addresses).select(:calendar_event_id))
    owned.or(invited)
  }

  # Everything a member may CHANGE. Deliberately narrower than `visible_to`:
  # being invited to a meeting must not let you retitle or delete it.
  scope :editable_by, ->(membership) {
    where(calendar_id: membership.organization.calendars.for_member(membership))
  }
  # A repeating series' master row. Its own start_at/end_at is the FIRST
  # occurrence, so it will not match `in_range` for later months — recurring
  # events must always be fetched by this scope, then expanded.
  scope :recurring_masters, -> { where.not(recurrence_rule: [nil, ""]).where(recurring_event_key: nil) }

  # Set on an expanded (unsaved) copy so callers/serializers can tell a single
  # occurrence apart from its series master. nil on every persisted row.
  attr_accessor :occurrence_start

  # Whether the member answering as `addresses` runs this meeting. Only the
  # organizer's edits and deletes are mailed to attendees — deleting an invite you
  # accepted must not send everyone a CANCEL in your name. A blank organizer is an
  # event from before invitations existed, which backfill_organizer! makes the
  # owner's on first touch.
  def organized_by?(addresses)
    organizer_email.blank? || addresses.any? { |a| a.to_s.casecmp?(organizer_email) }
  end

  def cancelled?
    status == STATUS_CANCELLED
  end

  def recurring_master?
    recurrence_rule.present? && recurring_event_key.blank?
  end

  # An exception row: one occurrence of a series that was moved, edited, or
  # (status cancelled) deleted. Identified by the original occurrence start so
  # expansion knows which generated instance it replaces.
  def occurrence_override?
    recurring_event_key.present?
  end

  def duration
    return 0 if start_at.blank? || end_at.blank?
    end_at - start_at
  end

  # The public id for this row — a virtual occurrence carries its start so the
  # client can address one instance of a series (RSVP/edit/delete "this").
  def occurrence_id
    return key if occurrence_start.blank?
    "#{key}#{OCCURRENCE_SEPARATOR}#{occurrence_start.utc.strftime('%Y%m%dT%H%M%SZ')}"
  end

  # Splits a public id back into [series_key, occurrence_start_or_nil].
  def self.parse_occurrence_id(id)
    series_key, stamp = id.to_s.split(OCCURRENCE_SEPARATOR, 2)
    return [series_key, nil] if stamp.blank?

    [series_key, Time.find_zone("UTC").strptime(stamp, "%Y%m%dT%H%M%SZ")]
  rescue ArgumentError
    [series_key, nil]
  end

  # Occurrence start times of this series that fall inside the range.
  # Expansion runs in the event's own timezone so a 09:00 weekly stays 09:00
  # across a DST boundary rather than sliding an hour.
  def occurrences_between(range_start, range_end)
    return [] if recurrence_rule.blank? || start_at.blank?

    zone = Time.find_zone(timezone.presence || "UTC") || Time.find_zone("UTC")
    schedule = IceCube::Schedule.new(start_at.in_time_zone(zone))
    schedule.add_recurrence_rule(IceCube::Rule.from_ical(normalized_recurrence_rule))
    # An occurrence starting before the window can still overlap it, so look
    # back one duration and let the caller's overlap filter do the trimming.
    schedule.occurrences_between(range_start - duration, range_end).first(MAX_OCCURRENCES)
  rescue StandardError => e
    # A rule we can't expand must not blank the whole calendar — the master row
    # still renders as a single event via the normal in-range path.
    Rails.logger.warn("[CalendarEvent] RRULE expansion failed for #{key}: #{e.message}")
    []
  end

  # Whether the series (as it stands in memory, saved or not) has an
  # occurrence starting exactly at `time`.
  def occurs_at?(time)
    occurrences_between(time, time + 1.second).any? { |t| t.to_i == time.to_i }
  end

  # An unsaved stand-in for one generated occurrence. Associations are
  # pre-populated from the master so serializing it costs no extra queries, and
  # it is readonly so it can never be persisted as a duplicate row.
  def build_occurrence(occ_start)
    copy = dup
    copy.start_at = occ_start
    copy.end_at = occ_start + duration
    copy.occurrence_start = occ_start
    copy.association(:calendar).target = calendar
    copy.association(:organization).target = organization
    copy.association(:attendees).target = attendees.to_a
    copy.association(:reminders).target = reminders.to_a
    copy.readonly!
    copy
  end

  # Ends the series immediately before `time` by pinning UNTIL — how "delete
  # this and following" works without writing an exception per future instance.
  def truncate_series_before!(time)
    # COUNT and UNTIL may not both be set (RFC 5545), and UNTIL is the new end.
    rule = IceCube::Rule.from_ical(normalized_recurrence_rule.gsub(/;?COUNT=\d+/i, "").sub(/\A;/, ""))
    update!(recurrence_rule: rule.until(time - 1.second).to_ical.sub(/\ARRULE:/, ""))
  rescue StandardError => e
    Rails.logger.warn("[CalendarEvent] RRULE truncate failed for #{key}: #{e.message}")
    raise
  end

  private

  def normalized_recurrence_rule
    recurrence_rule.to_s.strip.sub(/\ARRULE:/i, "")
  end

  def default_title
    self.title = "(Unnamed event)" if title.blank?
  end

  # RFC 5545 requires a globally unique UID; it is also how an inbound REPLY or
  # CANCEL finds this row again. Generated post-create so it can carry the key.
  # ponytail: the host half is cosmetic (UID uniqueness comes from the nanoid),
  # so it stays a constant rather than plumbing a per-org domain through.
  def assign_ical_uid
    update_column(:ical_uid, "#{key}@inbox2.com") if ical_uid.blank?
  end

  def end_after_start
    return if start_at.blank? || end_at.blank?
    errors.add(:end_at, "must be after start") if end_at <= start_at
  end
end
