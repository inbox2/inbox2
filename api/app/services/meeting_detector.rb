# Reads a booked meeting out of an email body that carries no ICS
# (docs/Meeting-Invites.md "Detected meetings") — "I confirm our appointment on
# Friday 7 October at 16:30 at Prins Alexanderlaan 151". Jev can't write values,
# so this is the OpenAI lane (Llm::Client), the same one that writes summaries.
#
# Returns {"title","start","end","location"} with floating wall-clock times
# (YYYY-MM-DDTHH:MM:00, the sender's clock, no zone) or nil. The local-channel
# twin is the `meeting` field of the Rust core's `[summary]` prompt, validated by
# `ics::DetectedMeeting::from_model` — keep the two rules in step.
class MeetingDetector
  PROMPT = <<~PROMPT.strip.freeze
    You read one email and decide whether it books or confirms one specific
    appointment or meeting the recipient takes part in, with a concrete date AND
    clock time (a viewing, a call, a visit, "I confirm our appointment on ... at ...").
    If it does, reply with STRICT JSON only:
    {"title": "<short English title>", "start": "YYYY-MM-DDTHH:MM", "end": "YYYY-MM-DDTHH:MM or null", "location": "<address or place, or null>"}
    Times exactly as written in the email, no time-zone conversion. Resolve a
    relative date ("next Friday") against the date the email was sent.
    A deadline, a proposal still being negotiated, several options to pick from,
    or a webinar / marketing event is NOT a meeting. Otherwise reply: null
  PROMPT

  # Cheap gate before paying for a call: no clock time in the text, no meeting.
  # ponytail: "16:30", "4.30pm", "16h30", "4 pm", "16 uur" — a time written in
  # words ("half vijf") slips through; widen this if that turns out to matter.
  CLOCK_TIME = /\b(?:[01]?\d|2[0-3])[:.h][0-5]\d\b|\b(?:1[0-2]|0?[1-9])\s?(?:am|pm)\b|\b(?:[01]?\d|2[0-3])\s?uur\b/i

  FORMAT = "%Y-%m-%dT%H:%M".freeze

  def self.detect(llm, subject:, text:, sent_at:)
    return nil unless llm.configured? && text.to_s.match?(CLOCK_TIME)

    user = "Subject: #{subject}\nSent: #{sent_at&.iso8601}\n\n#{text.to_s[0, 3000]}"
    meeting = parse(llm.complete(system: PROMPT, user: user, max_tokens: 120))
    # A meeting before the mail was sent is a misread one (same rule as the Rust
    # `meeting_is_plausible`).
    meeting unless meeting && sent_at && meeting["start"][0, 10] < sent_at.to_date.iso8601
  end

  # The model's reply → a validated hash, or nil. Anything malformed is no meeting.
  def self.parse(raw)
    json = raw.to_s[/\{.*\}/m] or return nil
    data = JSON.parse(json)
    start = time(data["start"]) or return nil
    finish = time(data["end"])
    finish = nil if finish && finish <= start
    {
      "title" => data["title"].to_s.strip.presence || "Meeting",
      "start" => start.strftime("#{FORMAT}:00"),
      "end" => finish&.strftime("#{FORMAT}:00"),
      "location" => data["location"].to_s.strip.presence
    }
  rescue JSON::ParserError
    nil
  end

  # Also takes a space or no separator for the T ("2026-10-0716:30", as small models
  # write it) — same rule as the Rust `DetectedMeeting::from_model`.
  def self.time(value)
    v = value.to_s
    DateTime.strptime("#{v[0, 10]}T#{v[10..].to_s.sub(/\A[T ]/, '')[0, 5]}", FORMAT)
  rescue ArgumentError
    nil
  end

  # The detected meeting served as a PUBLISH invite (MessageSerializer#invite), so
  # every client's existing "Add to calendar" branch renders it. `detected` marks
  # it as ours; the UID is stable per message so a second import upserts.
  def self.as_invite(message)
    m = message.detected_meeting
    {
      "method" => Message::CALENDAR_METHOD_PUBLISH, "uid" => "detected-#{message.key}@inbox2",
      "summary" => m["title"], "description" => nil, "location" => m["location"],
      "start" => m["start"], "end" => m["end"], "all_day" => false, "sequence" => 0,
      "organizer_email" => nil, "organizer_name" => nil, "detected" => true
    }
  end

  # For the import: the floating times resolved in the viewer's zone (an unknown
  # zone falls back to the org's).
  def self.zoned_invite(message, time_zone, organization)
    zone = ActiveSupport::TimeZone[time_zone.to_s] || ActiveSupport::TimeZone[organization.timezone.to_s] || Time.zone
    as_invite(message).merge(
      "timezone" => zone.tzinfo.name,
      "start" => zone.parse(message.detected_meeting["start"]).iso8601,
      "end" => message.detected_meeting["end"].presence && zone.parse(message.detected_meeting["end"]).iso8601
    )
  end
end
