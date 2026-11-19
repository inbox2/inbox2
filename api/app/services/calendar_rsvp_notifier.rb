# Mails a METHOD:REPLY to the organizer when a member answers an invitation
# through the calendar UI (docs/Calendar.md).
#
# The message-level RSVP path (MessagesController#rsvp) already did this for
# invitations answered from the reading pane. Answering the same meeting from
# the calendar screen wrote the attendee row and told nobody, so the organizer's
# view of who is coming depended on which screen the guest happened to use.
class CalendarRsvpNotifier
  def self.notify(event, attendee, membership)
    organizer = event.organizer_email.presence
    return nil if organizer.blank?
    # Our own event: the attendee list is already the source of truth.
    return nil if organizer.casecmp?(attendee.email.to_s)
    # needs_action / delegated are not answers — there is nothing to report.
    return nil unless IcsReply::PARTSTAT.key?(attendee.response_status)

    ics = IcsReply.build(invite_hash(event), attendee.email, attendee.response_status)
    conversation = event.organization.conversations.create!(
      subject: subject(event, attendee),
      from_address: attendee.email,
      to_address: organizer,
      status: Conversation::STATUS_OPEN
    )

    message = conversation.messages.create!(
      organization: event.organization,
      from_address: attendee.email,
      to_address: organizer,
      subject: subject(event, attendee),
      body_plain: "#{attendee.response_status.capitalize} the invitation “#{event.title}”.",
      content_type: "text/plain",
      calendar_reply: ics,
      is_inbound: false,
      is_draft: false
    )
    OutboundDeliveryJob.perform_later(message.id)
    message
  rescue StandardError => e
    # The RSVP itself is already recorded; failing to tell the organizer must
    # not fail the request.
    Rails.logger.warn("[CalendarRsvpNotifier] #{event.key}: #{e.message}")
    nil
  end

  # IcsReply speaks the message-level invite hash (string keys) — a stored event
  # carries the same fields under different names.
  def self.invite_hash(event)
    {
      "uid" => event.ical_uid,
      "sequence" => event.sequence.to_i,
      "organizer_email" => event.organizer_email,
      "summary" => event.title
    }
  end

  def self.subject(event, attendee)
    "#{attendee.response_status.capitalize}: #{event.title}"
  end

  private_class_method :invite_hash, :subject
end
