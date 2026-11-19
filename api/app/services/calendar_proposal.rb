# Counter-proposals: "can we do Tuesday instead?" (docs/Calendar.md).
#
# `propose-time` used to write proposed_start/proposed_end onto the attendee row
# and stop there — nothing mailed the organizer, nothing surfaced it, and no
# endpoint could act on it. A proposal nobody sees is just a dropped message.
#
# The loop is RFC 5546's: the attendee sends METHOD:COUNTER, the organizer either
# accepts (the event moves and a fresh REQUEST goes out with a bumped SEQUENCE)
# or declines (METHOD:DECLINECOUNTER, proposal cleared).
class CalendarProposal
  # Tells the organizer an attendee wants a different time.
  def self.notify(event, attendee, membership)
    organizer = event.organizer_email.presence
    return nil if organizer.blank?
    # Proposing against your own event is a no-op — just move it.
    return nil if organizer.casecmp?(attendee.email.to_s)
    return nil if attendee.proposed_start.blank?

    ics = IcsRequest.build(
      event,
      organizer_email: organizer,
      organizer_name: event.organizer_name,
      method: IcsRequest::METHOD_COUNTER,
      start_at: attendee.proposed_start,
      end_at: attendee.proposed_end || (attendee.proposed_start + event.duration)
    )

    deliver(event, from: attendee.email, to: organizer, ics: ics,
            subject: "New time proposed: #{event.title}",
            body: proposal_body(event, attendee))
  rescue StandardError => e
    # The proposal is already recorded; failing to mail it must not fail the
    # request.
    Rails.logger.warn("[CalendarProposal] notify #{event.key}: #{e.message}")
    nil
  end

  # Organizer accepts: the event moves to the proposed time. Returns the moved
  # event, or nil when there was no live proposal to accept.
  def self.accept!(event, attendee, membership)
    return nil if attendee.proposed_start.blank?

    new_start = attendee.proposed_start
    new_end = attendee.proposed_end || (new_start + event.duration)

    event.update!(
      start_at: new_start,
      end_at: new_end,
      # A moved invitation must outrank the one guests already hold.
      sequence: event.sequence.to_i + 1
    )
    # The proposal has been answered by the move itself, and whoever asked for
    # this time is implicitly happy with it.
    attendee.update!(
      proposed_start: nil, proposed_end: nil,
      response_status: CalendarAttendee::RESPONSE_ACCEPTED, responded_at: Time.current
    )
    # Everyone else's copy is now stale — clear their proposals too so the
    # organizer isn't left staring at suggestions for a slot that already moved.
    event.attendees.where.not(id: attendee.id).update_all(proposed_start: nil, proposed_end: nil)

    CalendarInviteDispatch.deliver(event.reload, membership)
    event
  end

  # Organizer says no: the attendee's client is told the counter was rejected,
  # and the proposal is cleared so it stops showing as pending.
  def self.decline!(event, attendee, membership)
    return nil if attendee.proposed_start.blank?

    organizer = event.organizer_email.presence
    if organizer.present? && !organizer.casecmp?(attendee.email.to_s)
      ics = IcsRequest.build(event, organizer_email: organizer, organizer_name: event.organizer_name,
                                    method: IcsRequest::METHOD_DECLINECOUNTER)
      deliver(event, from: organizer, to: attendee.email, ics: ics,
              subject: "Proposed time declined: #{event.title}",
              body: "The proposed new time for “#{event.title}” doesn't work. The meeting stays as scheduled.")
    end

    attendee.update!(proposed_start: nil, proposed_end: nil)
    event
  rescue StandardError => e
    Rails.logger.warn("[CalendarProposal] decline #{event.key}: #{e.message}")
    attendee.update(proposed_start: nil, proposed_end: nil)
    event
  end

  # Inbound METHOD:COUNTER from an external attendee's client.
  def self.apply_counter(organization, message, parsed)
    event = organization.calendar_events.where(ical_uid: parsed[:uid]).where(recurring_event_key: nil).first ||
      organization.calendar_events.find_by(ical_uid: parsed[:uid])
    return nil if event.nil? || parsed[:dtstart].blank?

    email = Array(parsed[:attendees]).first&.dig(:email).presence ||
      message.from_address.to_s[/[\w.+-]+@[\w.-]+/]
    return nil if email.blank?

    attendee = event.attendees.where("LOWER(email) = ?", email.downcase).first
    # Only someone actually invited may counter-propose.
    return nil if attendee.nil?

    attendee.update!(
      proposed_start: parsed[:dtstart],
      proposed_end: parsed[:dtend] || (parsed[:dtstart] + event.duration),
      response_status: CalendarAttendee::RESPONSE_TENTATIVE,
      responded_at: Time.current
    )
    broadcast(organization, event)
    Rails.logger.info("[CalendarProposal] #{email} proposed #{parsed[:dtstart]} on #{event.key}")
    event
  end

  def self.proposal_body(event, attendee)
    zone = Time.find_zone(event.timezone.presence || "UTC") || Time.find_zone("UTC")
    when_text = attendee.proposed_start.in_time_zone(zone).strftime("%a %-d %b %Y %H:%M")
    lines = ["#{attendee.name.presence || attendee.email} proposed a new time for “#{event.title}”.",
             "", "Proposed: #{when_text} (#{zone.name})"]
    lines << "" << attendee.comment if attendee.comment.present?
    lines.join("\n")
  end

  def self.deliver(event, from:, to:, ics:, subject:, body:)
    conversation = event.organization.conversations.create!(
      subject: subject, from_address: from, to_address: to, status: Conversation::STATUS_OPEN
    )
    message = conversation.messages.create!(
      organization: event.organization, from_address: from, to_address: to,
      subject: subject, body_plain: body, content_type: "text/plain",
      calendar_reply: ics, is_inbound: false, is_draft: false
    )
    OutboundDeliveryJob.perform_later(message.id)
    message
  end

  def self.broadcast(organization, event)
    ActionCable.server.broadcast("calendar_#{organization.key}",
                                 { type: "proposal_received", event_id: event.key })
  rescue StandardError => e
    Rails.logger.warn("[CalendarProposal] broadcast failed: #{e.message}")
  end

  private_class_method :proposal_body, :deliver, :broadcast
end
