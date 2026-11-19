# Minimal iCalendar (RFC 5545) parser for inbound .ics imports.
# Extracts VEVENT components into plain hashes consumed by
# CalendarEventsController#create_from_ics. Handles line unfolding,
# property parameters, text escaping, and DATE / DATE-TIME values
# (UTC "Z", floating, and TZID-qualified). It is intentionally lenient:
# unknown properties are ignored, and missing required fields are left
# for the model to validate. It raises IcsParser::ParseError only when
# the payload is not an iCalendar document at all.
class IcsParser
  class ParseError < StandardError; end

  def initialize(content)
    @content = content.to_s
  end

  # Returns an Array of event hashes with keys:
  # :uid, :summary, :description, :location, :dtstart, :dtend, :all_day,
  # :timezone, :organizer_email, :organizer_name, :rrule, :sequence, :status,
  # :recurrence_id, :attendees (an Array of {email:, name:, partstat:, optional:})
  def parse
    unless @content.include?("BEGIN:VCALENDAR")
      raise ParseError, "not an iCalendar document"
    end

    events = []
    current = nil
    method = nil # VCALENDAR-level METHOD (REQUEST/REPLY/CANCEL) — drives RSVP.

    unfolded_lines.each do |line|
      case line
      when "BEGIN:VEVENT"
        current = {}
      when "END:VEVENT"
        events << finalize(current).merge(method: method) if current
        current = nil
      else
        if current.nil?
          method = line.split(":", 2)[1] if line.start_with?("METHOD:")
          next
        end

        name, params, value = parse_line(line)
        assign(current, name, params, value) if name
      end
    end

    events
  end

  private

  # RFC 5545 line folding: a CRLF (or LF) followed by a single space or tab
  # is a continuation of the previous line. Unfold, then split into lines.
  def unfolded_lines
    @content
      .gsub("\r\n", "\n")
      .tr("\r", "\n")
      .gsub(/\n[ \t]/, "")
      .split("\n")
      .reject(&:empty?)
  end

  # Splits "NAME;PARAM=val;PARAM2=val:VALUE" into [name, params_hash, value].
  # The value is everything after the first colon (values may contain colons,
  # e.g. mailto: or URLs).
  def parse_line(line)
    colon = line.index(":")
    return [nil, nil, nil] unless colon

    prop = line[0...colon]
    value = line[(colon + 1)..].to_s

    segments = prop.split(";")
    name = segments.shift.to_s.upcase
    return [nil, nil, nil] if name.empty?

    params = {}
    segments.each do |seg|
      k, v = seg.split("=", 2)
      params[k.to_s.upcase] = v.to_s.delete('"') if k
    end

    [name, params, value]
  end

  def assign(event, name, params, value)
    case name
    when "UID"         then event[:uid] = value
    when "SUMMARY"     then event[:summary] = unescape(value)
    when "DESCRIPTION" then event[:description] = unescape(value)
    when "LOCATION"    then event[:location] = unescape(value)
    when "RRULE"       then event[:rrule] = value
    when "SEQUENCE"    then event[:sequence] = value.to_i
    when "STATUS"      then event[:status] = value.to_s.upcase.presence
    when "ORGANIZER"
      event[:organizer_email] = value.sub(/\Amailto:/i, "").presence
      event[:organizer_name] = params["CN"].presence
    when "ATTENDEE"
      # PARTSTAT on an inbound REPLY is the answer itself; on a REQUEST it is
      # the invitee list. Both are needed, so every ATTENDEE is collected.
      email = value.sub(/\Amailto:/i, "").strip.presence
      if email
        (event[:attendees] ||= []) << {
          email: email,
          name: params["CN"].presence,
          partstat: params["PARTSTAT"].presence,
          optional: params["ROLE"].to_s.casecmp?("OPT-PARTICIPANT")
        }
      end
    when "RECURRENCE-ID"
      event[:recurrence_id], = parse_datetime(value, params)
    when "DTSTART"
      time, all_day = parse_datetime(value, params)
      event[:dtstart] = time
      event[:all_day] = all_day
      event[:timezone] = zone_name(value, params)
    when "DTEND"
      event[:dtend], = parse_datetime(value, params)
    when "DURATION"
      event[:_duration] = value
    end
  end

  # Fill in derived fields the model needs (e.g. an end time when only a
  # start + DURATION, or an all-day start, was supplied).
  def finalize(event)
    if event[:dtend].nil? && event[:dtstart]
      event[:dtend] =
        if event[:_duration]
          event[:dtstart] + parse_duration(event[:_duration])
        elsif event[:all_day]
          event[:dtstart] + 1.day
        end
    end
    event.delete(:_duration)
    event
  end

  def parse_datetime(value, params)
    v = value.to_s.strip

    if params["VALUE"] == "DATE" || v.match?(/\A\d{8}\z/)
      return [Time.find_zone("UTC").strptime(v, "%Y%m%d"), true]
    end

    digits = v.delete("Z")
    [Time.find_zone(zone_name(value, params)).strptime(digits, "%Y%m%dT%H%M%S"), false]
  rescue ArgumentError
    raise ParseError, "invalid date value: #{value.inspect}"
  end

  def zone_name(value, params)
    return "UTC" if value.to_s.strip.end_with?("Z")
    return params["TZID"] if params["TZID"] && Time.find_zone(params["TZID"])

    "UTC"
  end

  # Parses an RFC 5545 duration (e.g. "PT1H30M", "P1D") into seconds.
  def parse_duration(str)
    m = str.to_s.match(/\AP(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/)
    return 1.hour unless m

    weeks, days, hours, mins, secs = m.captures.map { |c| c.to_i }
    (weeks.weeks + days.days + hours.hours + mins.minutes + secs.seconds).tap do |d|
      return 1.hour if d.zero?
    end
  end

  def unescape(text)
    text.to_s.gsub(/\\([\\;,nN])/) { |_| Regexp.last_match(1).downcase == "n" ? "\n" : Regexp.last_match(1) }
  end
end
