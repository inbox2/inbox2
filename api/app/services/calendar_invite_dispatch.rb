# Mails a calendar event to its attendees as a real invitation
# (docs/Calendar.md). Until this existed, adding attendees to an event wrote
# `calendar_attendees` rows and told nobody — while the compose UI already
# promised "An .ics calendar file is attached".
#
# The invite rides the normal outbound pipeline (Message + OutboundDeliveryJob),
# so DKIM signing, suppression and delivery tracking apply unchanged. The ICS
# goes in `messages.calendar_reply`, the column OutboundMailPublisher already
# turns into a text/calendar part — it reads the METHOD out of the body, so the
# same column carries REQUEST, CANCEL and REPLY.
class CalendarInviteDispatch
  ACTION_REQUEST = :request
  ACTION_CANCEL = :cancel

  # The event's organizer address is not one the acting member may send as.
  class SenderNotAllowed < StandardError; end

  def self.deliver(event, membership, action: ACTION_REQUEST)
    new(event, membership, action).deliver
  end

  def initialize(event, membership, action)
    @event = event
    @membership = membership
    @action = action
  end

  # Returns the outbound Message, or nil when there is nothing/nobody to send.
  def deliver
    return nil if recipients.empty?

    if organizer_email.blank?
      # A member with no Mailbox row has no address to send from. Silently
      # dropping would look like a delivered invite, so it is logged loudly.
      Rails.logger.warn("[CalendarInviteDispatch] #{@event.key}: no organizer address, invite not sent")
      return nil
    end

    # Same sender rule as messages and drafts (Membership#can_send_as?): the
    # invitation leaves DKIM-signed From this address, so it must be one of the
    # acting member's own. An imported invite keeps its external organizer; its
    # attendee list is theirs to change, not ours to re-send.
    if @membership && !@membership.can_send_as?(organizer_email)
      raise SenderNotAllowed, "#{@membership.key} may not send invitations as #{organizer_email}"
    end

    message = conversation.messages.create!(
      organization: @event.organization,
      from_address: organizer_email,
      to_address: recipients.join(", "),
      subject: subject,
      body_plain: body,
      content_type: "text/plain",
      calendar_reply: ics,
      is_inbound: false,
      is_draft: false
    )
    OutboundDeliveryJob.perform_later(message.id)
    Rails.logger.info("[CalendarInviteDispatch] #{@action} for #{@event.key} to #{recipients.size} attendee(s)")
    message
  end

  private

  def cancel?
    @action == ACTION_CANCEL
  end

  def organizer_email
    @organizer_email ||= @event.organizer_email.presence || @membership&.primary_email_address
  end

  # Never mail the organizer their own invitation.
  def recipients
    @recipients ||= @event.attendees
      .reject { |a| a.email.blank? || a.email.casecmp?(organizer_email.to_s) }
      .map(&:email)
      .uniq
  end

  def ics
    IcsRequest.build(
      @event,
      organizer_email: organizer_email,
      organizer_name: @membership&.user&.display_name,
      method: cancel? ? IcsRequest::METHOD_CANCEL : IcsRequest::METHOD_REQUEST
    )
  end

  # Reuses the event's conversation so a later update or cancellation threads
  # under the original invitation instead of starting a new one.
  def conversation
    @conversation ||= begin
      existing = @event.conversation_key.present? &&
        @event.organization.conversations.find_by(key: @event.conversation_key)
      existing || create_conversation
    end
  end

  def create_conversation
    convo = @event.organization.conversations.create!(
      subject: subject,
      from_address: organizer_email,
      to_address: recipients.first,
      status: Conversation::STATUS_OPEN
    )
    @event.update_column(:conversation_key, convo.key)
    convo
  end

  def subject
    prefix = if cancel?
      "Cancelled"
    elsif @event.sequence.to_i.positive?
      "Updated invitation"
    else
      "Invitation"
    end
    "#{prefix}: #{@event.title} @ #{when_text}"
  end

  def when_text
    zone = Time.find_zone(@event.timezone.presence || "UTC") || Time.find_zone("UTC")
    start = @event.start_at.in_time_zone(zone)
    return start.strftime("%a %-d %b %Y") if @event.all_day?

    "#{start.strftime('%a %-d %b %Y %H:%M')} (#{zone.name})"
  end

  def body
    lines = []
    lines << (cancel? ? "This event has been cancelled." : "You have been invited to the following event.")
    lines << ""
    lines << "#{@event.title}"
    lines << "When: #{when_text}"
    lines << "Where: #{@event.location}" if @event.location.present?
    lines << "Organizer: #{organizer_email}"
    lines << ""
    lines << @event.description if @event.description.present?
    lines.join("\n")
  end
end
