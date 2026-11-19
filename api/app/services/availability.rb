# The scheduling assistant's data source (docs/Calendar.md): who is free when,
# and which slots actually work for everybody.
#
# Answers the Exchange/Google "find a time" question in one round trip — the
# popup needs each person's identity, timezone, working day and busy blocks all
# at once, and firing five requests to draw one grid is silly.
#
# Busy lookup is deliberately ORG-WIDE. Free/busy exists precisely to answer
# "is this person free" without exposing their calendar, so it reads across
# colleagues' private calendars but returns only start/end times. Titles come
# back solely for events the caller could already open (see FreeBusy).
class Availability
  # Working hours come from each person's own profile (`users.working_hours`,
  # edited in Settings › Account) and are evaluated in their own timezone.
  # Someone who never set them falls back to User::DEFAULT_WORKING_HOURS.

  # Candidate slots are considered on this grid; a 30-minute lattice is what
  # both Outlook and Google offer and keeps the scan cheap.
  SLOT_MINUTES = 30
  DEFAULT_DURATION_MINUTES = 30
  MAX_SUGGESTIONS = 12
  # Hard stop on the scan so a year-wide window can't spin.
  MAX_SLOTS_SCANNED = 2000

  def initialize(organization:, membership:, emails:, range_start:, range_end:, duration_minutes: nil)
    @organization = organization
    @membership = membership
    @emails = Array(emails).filter_map { |e| e.to_s.downcase.presence }.uniq
    @range_start = range_start
    @range_end = range_end
    @duration = (duration_minutes.presence || DEFAULT_DURATION_MINUTES).to_i.clamp(5, 24 * 60).minutes
  end

  def call
    { attendees: attendees, suggestions: suggestions }
  end

  private

  def directory
    @directory ||= OrgDirectory.new(@organization, membership: @membership).resolve(@emails)
  end

  def busy_by_email
    @busy_by_email ||= FreeBusy.new(
      CalendarEvent.where(organization_id: @organization.id),
      @emails, @range_start, @range_end,
      detail_calendar_ids: viewer_calendar_ids,
      organization: @organization
    ).call
  end

  # Calendars the requesting member can already read — the only events whose
  # titles are safe to include.
  def viewer_calendar_ids
    @viewer_calendar_ids ||= @organization.calendars.for_member(@membership).pluck(:id)
  end

  def attendees
    @attendees ||= @emails.map do |email|
      person = directory[email]
      {
        email: email,
        name: person.name,
        internal: person.internal?,
        timezone: person.timezone,
        # An outside guest has no calendar here, so "no busy blocks" means
        # "unknown", not "free". The client must not draw them as available.
        availability_known: person.internal?,
        working_hours: person.internal? ? working_hours_for(person) : nil,
        out_of_office: out_of_office_for(person),
        busy: busy_with_out_of_office(person, busy_by_email[email] || [])
      }
    end
  end

  def working_hours_for(person)
    hours = person.user&.effective_working_hours || User::DEFAULT_WORKING_HOURS
    {
      timezone: person.timezone,
      start_minute: hours["start_minute"],
      end_minute: hours["end_minute"],
      days: hours["days"]
    }
  end

  # Reported as its own field so the grid can label the row "Out of office"
  # rather than just showing an unexplained wall of busy.
  def out_of_office_for(person)
    overlap = person.user&.out_of_office_overlap(@range_start, @range_end)
    return nil if overlap.nil?

    { start: overlap.first, end: overlap.last, message: person.user.out_of_office_message.presence }
  end

  # Being away is being busy: an OOO period blocks slots exactly like a booked
  # meeting, so suggestions never land in someone's holiday. Merged through
  # FreeBusy's overlap logic so it doesn't double up with real events.
  def busy_with_out_of_office(person, busy)
    ooo = out_of_office_for(person)
    return busy if ooo.nil?

    FreeBusy.merge_periods(busy + [{ start: ooo[:start], end: ooo[:end], out_of_office: true }])
  end

  # Slots inside the window where every attendee whose calendar we can actually
  # see is free. Ranked so slots inside everyone's working day come first —
  # a technically-free 03:00 is not a real suggestion.
  def suggestions
    found = []
    cursor = align_to_slot(@range_start)
    scanned = 0

    while cursor + @duration <= @range_end && scanned < MAX_SLOTS_SCANNED
      scanned += 1
      finish = cursor + @duration

      if attendees.none? { |a| a[:availability_known] && busy?(a, cursor, finish) }
        outside = attendees.select { |a| a[:working_hours] && !within_working_hours?(a, cursor, finish) }
        found << {
          start: cursor,
          end: finish,
          outside_working_hours: outside.map { |a| a[:email] }
        }
      end
      cursor += SLOT_MINUTES.minutes
    end

    found
      .sort_by { |slot| [slot[:outside_working_hours].size, slot[:start]] }
      .first(MAX_SUGGESTIONS)
  end

  def align_to_slot(time)
    step = SLOT_MINUTES.minutes
    Time.zone.at((time.to_i / step.to_i.to_f).ceil * step.to_i)
  end

  def busy?(attendee, from, to)
    attendee[:busy].any? { |b| b[:start] < to && b[:end] > from }
  end

  # Evaluated in the attendee's own timezone — 09:00 means their morning, not
  # the caller's. A slot spilling past the end of their day counts as outside.
  def within_working_hours?(attendee, from, to)
    hours = attendee[:working_hours]
    zone = Time.find_zone(hours[:timezone]) || Time.find_zone("UTC")
    local_start = from.in_time_zone(zone)
    local_end = to.in_time_zone(zone)

    return false unless hours[:days].include?(local_start.wday)

    start_minutes = (local_start.hour * 60) + local_start.min
    return false unless start_minutes >= hours[:start_minute]

    # An exact finish on the boundary (17:00) is still inside the day.
    finish_minutes = (local_end.hour * 60) + local_end.min
    local_start.to_date == local_end.to_date && finish_minutes <= hours[:end_minute]
  end
end
