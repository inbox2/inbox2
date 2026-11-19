# Builds a METHOD:REPLY iCalendar body answering an emailed meeting invite
# (docs/Meeting-Invites.md). Echoes the request's UID + SEQUENCE so the
# organizer's client correlates the reply to the right event/version.
class IcsReply
  # RFC 5545 attendee status for each answerable RSVP verb.
  PARTSTAT = {
    "accepted" => "ACCEPTED",
    "declined" => "DECLINED",
    "tentative" => "TENTATIVE"
  }.freeze

  # `invite` is the message's stored calendar_invite hash (string keys).
  def self.build(invite, attendee_email, response, now: Time.now.utc)
    partstat = PARTSTAT.fetch(response)
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    body = <<~ICS
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//inbox2//invite//EN
      METHOD:REPLY
      BEGIN:VEVENT
      UID:#{invite['uid']}
      SEQUENCE:#{invite['sequence'].to_i}
      DTSTAMP:#{stamp}
      ORGANIZER:mailto:#{invite['organizer_email']}
      ATTENDEE;PARTSTAT=#{partstat}:mailto:#{attendee_email}
      SUMMARY:#{escape(invite['summary'].to_s)}
      END:VEVENT
      END:VCALENDAR
    ICS
    body.gsub("\n", "\r\n")
  end

  def self.escape(text)
    text.gsub("\\", "\\\\\\\\").gsub(";", "\\;").gsub(",", "\\,").gsub("\n", "\\n")
  end
end
