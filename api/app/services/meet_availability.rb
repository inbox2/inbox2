# The public availability behind a meet link (docs/Calendar.md): the invitee's
# merged busy blocks — calendar events, out of office, blocked time — plus the
# working-hours envelope, and nothing else. Deliberately NOT Availability#call:
# that payload carries names, emails and timezones of arbitrary attendees; a
# visitor gets bare start/end pairs for one person.
class MeetAvailability
  def initialize(link, range_start, range_end)
    @link = link
    @range_start = range_start
    @range_end = range_end
  end

  # => { busy: [{start:, end:}], working_hours: {...}, timezone: "..." }
  # Busy is clipped to working hours: the page greys everything outside them
  # anyway, and a visitor has no business learning what fills your evenings.
  def payload
    {
      busy: within_working_windows(busy).map { |b| { start: b[:start].iso8601, end: b[:end].iso8601 } },
      working_hours: working_hours,
      timezone: timezone
    }
  end

  # Can this exact slot be requested? Free, inside the invitee's working hours,
  # and inside the link's notice/lookahead window.
  def bookable?(from, to)
    @link.window.cover?(from) &&
      within_working_hours?(from, to) &&
      busy.none? { |b| b[:start] < to && b[:end] > from }
  end

  # Busy-overlap only — the accept-side conflict report. The visitor-facing
  # notice/lookahead window and working hours deliberately don't apply: an
  # invitee accepting late or off-hours is their call, not a conflict.
  def slot_free?(from, to)
    busy.none? { |b| b[:start] < to && b[:end] > from }
  end

  def timezone
    user&.default_timezone.presence || "UTC"
  end

  def working_hours
    hours = user&.effective_working_hours || User::DEFAULT_WORKING_HOURS
    {
      timezone: timezone,
      start_minute: hours["start_minute"],
      end_minute: hours["end_minute"],
      days: hours["days"]
    }
  end

  private

  def invitee = @link.invitee_membership
  def user = invitee.user

  def busy
    @busy ||= begin
      by_email = FreeBusy.new(
        CalendarEvent.where(organization_id: @link.organization_id),
        invitee.email_addresses.map(&:downcase),
        @range_start, @range_end,
        organization: @link.organization
      ).call
      # No detail_calendar_ids were passed, so no titles ride along — but strip
      # to bare periods anyway: this hash reaches an unauthenticated response.
      periods = by_email.values.flatten.map { |b| { start: b[:start], end: b[:end] } }

      if (ooo = user&.out_of_office_overlap(@range_start, @range_end))
        periods << { start: ooo.first, end: ooo.last }
      end

      FreeBusy.merge_periods(periods)
    end
  end

  # `periods` cut down to the parts inside each working day of the range.
  def within_working_windows(periods)
    hours = working_hours
    zone = Time.find_zone(hours[:timezone]) || Time.find_zone("UTC")
    first = @range_start.in_time_zone(zone).to_date
    last = @range_end.in_time_zone(zone).to_date
    windows = (first..last).select { |day| hours[:days].include?(day.wday) }.map do |day|
      # Wall-clock boundaries, so a DST change day keeps 09:00–17:00. A boundary
      # inside the spring-forward gap (02:30 that day) means the first instant
      # past the gap — the transition, which within_working_hours? accepts — not
      # 02:30 shifted on by the gap's length.
      at = lambda do |minute|
        next zone.local((day + 1).year, (day + 1).month, (day + 1).day) if minute >= 24 * 60 # "until 24:00"
        t = zone.local(day.year, day.month, day.day, minute / 60, minute % 60)
        next t if (t.hour * 60) + t.min == minute

        zone.tzinfo.period_for_utc(t.utc).starts_at.to_time.in_time_zone(zone)
      end
      [at.(hours[:start_minute]), at.(hours[:end_minute])]
    end

    windows.flat_map do |from, to|
      periods.filter_map do |p|
        s = [p[:start], from].max
        e = [p[:end], to].min
        { start: s, end: e } if s < e
      end
    end
  end

  # Same evaluation as Availability#within_working_hours?, in the invitee's zone.
  def within_working_hours?(from, to)
    hours = working_hours
    zone = Time.find_zone(hours[:timezone]) || Time.find_zone("UTC")
    local_start = from.in_time_zone(zone)
    local_end = to.in_time_zone(zone)

    return false unless hours[:days].include?(local_start.wday)

    start_minutes = (local_start.hour * 60) + local_start.min
    return false unless start_minutes >= hours[:start_minute]

    finish_minutes = (local_end.hour * 60) + local_end.min
    local_start.to_date == local_end.to_date && finish_minutes <= hours[:end_minute]
  end
end
