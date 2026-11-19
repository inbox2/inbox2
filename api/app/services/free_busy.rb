# Busy blocks for a set of addresses over a window (docs/Calendar.md). The one
# busy engine behind both `GET /events/free-busy` and the scheduling assistant.
#
# Busy-only by default: a block is a start and an end, nothing else. A title
# rides along only for events the caller can already open anyway, which is what
# `detail_calendar_ids` names — so showing a colleague's day never reveals more
# than their calendar already would.
#
# Two corrections over the query this replaces:
#
#   1. Being the ORGANIZER counts as busy. The old version joined
#      calendar_attendees only, so an event you created but never added
#      yourself to as an attendee left you looking free during your own meeting.
#   2. Recurring series are expanded, so a weekly standup blocks every week
#      rather than only the day the series began.
class FreeBusy
  # `organization:` additionally folds members' blocked times (docs/Calendar.md
  # meet links) into busy — a blocked window must read exactly like a booked
  # meeting, to colleagues and meet-link visitors alike.
  def initialize(scope, emails, range_start, range_end, detail_calendar_ids: nil, organization: nil)
    @scope = scope
    @emails = emails.map { |e| e.to_s.downcase }.uniq
    @range_start = range_start
    @range_end = range_end
    @detail_calendar_ids = detail_calendar_ids && Set.new(detail_calendar_ids)
    @organization = organization
  end

  # => { "someone@example.com" => [{ start:, end:, title? }, ...] }
  # Addresses with nothing booked are omitted rather than mapped to [], keeping
  # the response shape clients already parse.
  def call
    return {} if @emails.empty?

    blocks = Hash.new { |h, k| h[k] = [] }

    occurrences.each do |event|
      block = { start: event.start_at, end: event.end_at }
      block[:title] = event.title if detail?(event)
      busy_emails_for(event).each { |email| blocks[email] << block.dup }
    end

    blocked_periods.each { |email, periods| blocks[email].concat(periods) }

    blocks.transform_values { |periods| self.class.merge_periods(periods) }
  end

  # Overlapping/adjacent blocks collapse into one — the caller wants gaps, and a
  # series plus a moved exception can otherwise report the same hour twice. The
  # surviving block keeps a title only if both sides agreed on one, and stays
  # flagged out-of-office if either side was.
  #
  # A class method because Availability folds out-of-office periods in as busy
  # blocks and needs the same collapsing.
  def self.merge_periods(periods)
    periods.sort_by { |p| p[:start] }.each_with_object([]) do |period, merged|
      last = merged.last
      if last && period[:start] <= last[:end]
        last[:end] = period[:end] if period[:end] > last[:end]
        last.delete(:title) unless last[:title] == period[:title]
        last[:out_of_office] = true if period[:out_of_office]
      else
        merged << period.dup
      end
    end
  end

  private

  def detail?(event)
    @detail_calendar_ids&.include?(event.calendar_id)
  end

  def occurrences
    CalendarOccurrences.for_range(@scope.includes(:attendees), @range_start, @range_end)
  end

  # Members' "not available" windows and device-uploaded busy, mapped back
  # onto their addresses. Never carries a title — a blocked window is
  # indistinguishable from a meeting by design.
  def blocked_periods
    return {} unless @organization

    blocks = Hash.new { |h, k| h[k] = [] }
    # Busy uploaded from members' devices (their local Gmail/Office365
    # calendars) reads exactly like blocked time.
    [BlockedTime.all, ExternalBusyBlock.live].each do |scope|
      scope.where(organization: @organization)
        .in_range(@range_start, @range_end)
        .includes(membership: :mailboxes)
        .each do |blocked|
          emails = blocked.membership.email_addresses.map(&:downcase) & @emails
          emails.each { |email| blocks[email] << { start: blocked.start_at, end: blocked.end_at } }
        end
    end
    blocking_zones.each { |email, periods| blocks[email].concat(periods) }
    blocks
  end

  # Zones with "Block this time" on. Zones belong to the user, not the
  # membership, so one blocks its owner in every org they're in.
  def blocking_zones
    members = @organization.memberships.joins(mailboxes: :domain)
      .where("LOWER(mailboxes.local_part || '@' || domains.name) IN (?)", @emails)
      .distinct.includes(mailboxes: :domain)
      .map { |m| [m.user_id, m.email_addresses.map(&:downcase) & @emails] }
    return {} if members.empty?

    emails_by_user = members.group_by(&:first).transform_values { |rows| rows.flat_map(&:last) }
    blocks = Hash.new { |h, k| h[k] = [] }
    Zone.where(user_id: emails_by_user.keys, blocks: true).touching(@range_start, @range_end).each do |zone|
      zone.occurrences(@range_start, @range_end).each do |o|
        emails_by_user[zone.user_id].each { |email| blocks[email] << { start: o.start_at, end: o.end_at } }
      end
    end
    blocks
  end

  # A declined invitation does not make you busy; organizing does regardless of
  # whether an attendee row exists for you.
  def busy_emails_for(event)
    organizer = event.organizer_email.to_s.downcase
    attending = event.attendees
      .reject { |a| a.response_status == CalendarAttendee::RESPONSE_DECLINED }
      .map { |a| a.email.to_s.downcase }

    (attending + [organizer]).uniq & @emails
  end
end
