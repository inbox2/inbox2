# Builds the METHOD:REQUEST / METHOD:CANCEL iCalendar body that turns an
# inbox2 calendar event into a real invitation in the recipient's client
# (docs/Calendar.md). Counterpart to IcsReply, which answers someone else's.
#
# Deliberately hand-rolled in the same style as IcsReply rather than routed
# through the `icalendar` gem: the reply builder already proves this shape works
# against Gmail/Outlook, and the gem's timezone-value handling is a bigger
# surface than the ~40 lines it would save.
class IcsRequest
  METHOD_REQUEST = "REQUEST".freeze
  METHOD_CANCEL = "CANCEL".freeze
  # RFC 5546 counter-proposals: an attendee suggesting a different time, and the
  # organizer turning that suggestion down.
  METHOD_COUNTER = "COUNTER".freeze
  METHOD_DECLINECOUNTER = "DECLINECOUNTER".freeze

  # RFC 5545 caps a content line at 75 octets; longer lines fold onto a
  # continuation line beginning with a single space.
  FOLD_WIDTH = 73

  # `start_at`/`end_at` override the event's own times — a COUNTER carries the
  # times being *proposed*, not the ones currently on the event.
  def self.build(event, organizer_email:, organizer_name: nil, method: METHOD_REQUEST,
                 start_at: nil, end_at: nil, now: Time.now.utc)
    new(event, organizer_email, organizer_name, method, now, start_at, end_at).build
  end

  def initialize(event, organizer_email, organizer_name, method, now, start_at = nil, end_at = nil)
    @event = event
    @organizer_email = organizer_email
    @organizer_name = organizer_name
    @method = method
    @now = now
    @start_at = start_at
    @end_at = end_at
  end

  def build
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//inbox2//calendar//EN",
             "CALSCALE:GREGORIAN", "METHOD:#{@method}", "BEGIN:VEVENT"]

    lines << "UID:#{@event.ical_uid}"
    lines << "SEQUENCE:#{@event.sequence.to_i}"
    lines << "DTSTAMP:#{utc_stamp(@now)}"
    lines << date_line("DTSTART", @start_at || @event.start_at)
    lines << date_line("DTEND", @end_at || @event.end_at)
    lines << "SUMMARY:#{escape(@event.title.to_s)}"
    lines << "DESCRIPTION:#{escape(@event.description.to_s)}" if @event.description.present?
    lines << "LOCATION:#{escape(@event.location.to_s)}" if @event.location.present?
    lines << "RRULE:#{@event.recurrence_rule}" if @event.recurrence_rule.present?
    # A moved/edited single instance of a series must say which one it replaces,
    # or the recipient's client treats it as a whole separate event.
    lines << date_line("RECURRENCE-ID", @event.original_start_at) if @event.original_start_at.present?
    lines << "STATUS:#{cancel? ? 'CANCELLED' : 'CONFIRMED'}"
    lines << organizer_line
    attendee_lines(lines)

    lines << "END:VEVENT"
    lines << "END:VCALENDAR"

    lines.flat_map { |line| fold(line) }.join("\r\n") + "\r\n"
  end

  private

  def cancel?
    @method == METHOD_CANCEL
  end

  def organizer_line
    cn = @organizer_name.present? ? ";CN=#{escape(@organizer_name)}" : ""
    "ORGANIZER#{cn}:mailto:#{@organizer_email}"
  end

  def attendee_lines(lines)
    @event.attendees.each do |att|
      next if att.email.casecmp?(@organizer_email.to_s)

      params = []
      params << "CN=#{escape(att.name)}" if att.name.present?
      params << "ROLE=#{att.is_optional? ? 'OPT-PARTICIPANT' : 'REQ-PARTICIPANT'}"
      params << "PARTSTAT=#{partstat(att.response_status)}"
      # A cancellation is informational — asking for a fresh answer to a
      # meeting that no longer exists makes clients show a stray RSVP prompt.
      params << "RSVP=TRUE" unless cancel?
      lines << "ATTENDEE;#{params.join(';')}:mailto:#{att.email}"
    end
  end

  def partstat(response_status)
    IcsReply::PARTSTAT.fetch(response_status.to_s, "NEEDS-ACTION")
  end

  # All-day events carry a floating DATE; everything else goes out in UTC so
  # there is no VTIMEZONE component to get wrong.
  def date_line(name, time)
    return "#{name}:#{utc_stamp(@now)}" if time.blank?
    return "#{name};VALUE=DATE:#{time.utc.strftime('%Y%m%d')}" if @event.all_day?

    "#{name}:#{utc_stamp(time)}"
  end

  def utc_stamp(time)
    time.utc.strftime("%Y%m%dT%H%M%SZ")
  end

  def fold(line)
    return [line] if line.bytesize <= FOLD_WIDTH + 2

    chunks = line.scan(/.{1,#{FOLD_WIDTH}}/m)
    [chunks.first, *chunks[1..].map { |c| " #{c}" }]
  end

  def escape(text)
    IcsReply.escape(text.to_s)
  end
end
