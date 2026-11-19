# Applies an inbound METHOD:REPLY or METHOD:CANCEL to the calendar
# (docs/Calendar.md). Without it, invitations we send are write-only: attendees
# answer, their clients mail a perfectly good REPLY, and the organizer's
# attendee list sits on "needs_action" forever.
#
# Correlation is by ical_uid, which is why CalendarEvent assigns one on create.
class InboundCalendarResponse
  # RFC 5545 PARTSTAT -> CalendarAttendee.response_status. DELEGATED and
  # the *-ACTION spellings collapse to needs_action: someone still owes an answer.
  PARTSTAT_TO_STATUS = {
    "ACCEPTED" => CalendarAttendee::RESPONSE_ACCEPTED,
    "DECLINED" => CalendarAttendee::RESPONSE_DECLINED,
    "TENTATIVE" => CalendarAttendee::RESPONSE_TENTATIVE,
    "NEEDS-ACTION" => CalendarAttendee::RESPONSE_NEEDS_ACTION,
    "DELEGATED" => CalendarAttendee::RESPONSE_NEEDS_ACTION
  }.freeze

  def self.apply_reply(organization, message, parsed)
    event = find_event(organization, parsed)
    return nil if event.nil?

    # The replying party is whoever the ATTENDEE line names; the envelope
    # sender is the fallback for clients that omit it.
    responder = Array(parsed[:attendees]).first
    email = responder&.dig(:email).presence || sender_address(message)
    status = PARTSTAT_TO_STATUS[responder&.dig(:partstat).to_s.upcase]
    return nil if email.blank? || status.blank?

    attendee = find_or_build_attendee(event, email)
    attendee.name = responder[:name] if responder&.dig(:name).present? && attendee.name.blank?
    attendee.response_status = status
    attendee.responded_at = Time.current
    attendee.save!

    broadcast(organization, event, "rsvp_updated")
    Rails.logger.info("[InboundCalendarResponse] #{email} -> #{status} on #{event.key}")
    event
  end

  def self.apply_cancel(organization, message, parsed)
    event = find_event(organization, parsed)
    # Also flag the original invitation so the reading pane can show the
    # meeting is off, whether or not it was ever added to a calendar.
    mark_invite_cancelled(organization, parsed[:uid])
    return nil if event.nil? || event.cancelled?

    event.update!(status: CalendarEvent::STATUS_CANCELLED)
    broadcast(organization, event, "event_cancelled")
    Rails.logger.info("[InboundCalendarResponse] cancelled #{event.key} via inbound CANCEL")
    event
  end

  def self.find_event(organization, parsed)
    return nil if parsed[:uid].blank?

    scope = organization.calendar_events.where(ical_uid: parsed[:uid])
    # A series and its exceptions share one UID (RFC 5545), so a RECURRENCE-ID
    # picks out the single instance and its absence means the series itself —
    # hence ordering the master (no recurring_event_key) first.
    if parsed[:recurrence_id].present?
      scope.find_by(original_start_at: parsed[:recurrence_id]) || series_master(scope)
    else
      series_master(scope)
    end
  end

  def self.series_master(scope)
    scope.where(recurring_event_key: nil).first || scope.first
  end

  # Emails are case-insensitive, and the stored side came from user input, so
  # the match must be too or every reply creates a duplicate attendee row.
  def self.find_or_build_attendee(event, email)
    event.attendees.where("LOWER(email) = ?", email.downcase).first ||
      event.attendees.build(email: email)
  end

  def self.mark_invite_cancelled(organization, uid)
    return if uid.blank?

    organization.messages.where("calendar_invite->>'uid' = ?", uid).find_each do |msg|
      msg.update!(calendar_invite: msg.calendar_invite.merge("cancelled" => true))
    end
  rescue StandardError => e
    Rails.logger.warn("[InboundCalendarResponse] could not flag cancelled invite #{uid}: #{e.message}")
  end

  def self.sender_address(message)
    message.from_address.to_s[/[\w.+-]+@[\w.-]+/]
  end

  def self.broadcast(organization, event, type)
    ActionCable.server.broadcast("calendar_#{organization.key}", { type: type, event_id: event.key })
  rescue StandardError => e
    Rails.logger.warn("[InboundCalendarResponse] broadcast failed: #{e.message}")
  end

  private_class_method :find_event, :series_master, :find_or_build_attendee,
                       :mark_invite_cancelled, :sender_address, :broadcast
end
