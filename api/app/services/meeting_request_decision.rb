# Accept/decline for a meet-link meeting request (docs/Calendar.md). Accept is
# where the calendar finally gets touched: the event is created with the
# INVITEE as organizer and the visitor as an already-accepted attendee, then
# mailed as a real METHOD:REQUEST invite through CalendarInviteDispatch — the
# visitor never becomes an organizer, and the invitee controls the invite,
# its updates and its cancellation.
class MeetingRequestDecision
  Result = Struct.new(:event, :conflict, :conference_error, keyword_init: true)

  def self.accept(request, membership)
    new(request, membership).accept
  end

  def self.decline(request, membership, reason: nil)
    new(request, membership).decline(reason)
  end

  def initialize(request, membership)
    @request = request
    @membership = membership
    @link = request.meet_link
  end

  # Returns nil when the request was already decided (a concurrent accept or
  # decline won the row lock) — the caller reports "already answered".
  def accept
    # The slot may have filled since the request came in. Accepting is still
    # the invitee's call — it's their calendar — so a conflict is reported,
    # never enforced. Busy-overlap only: the visitor-facing notice window
    # doesn't apply to the invitee (a late accept is not a "conflict").
    conflict = !MeetAvailability.new(@link, @request.start_at, @request.end_at)
      .slot_free?(@request.start_at, @request.end_at)

    event = nil
    # with_lock closes the controller's check-then-act gap: two concurrent
    # decisions serialize on the row and the loser sees a decided status.
    decided = @request.with_lock do
      next false if @request.expire_if_stale!
      next false unless @request.pending?

      event = create_event
      @request.update!(status: MeetingRequest::STATUS_ACCEPTED, calendar_event: event)
      true
    end
    return nil unless decided

    # External HTTP (token refresh + Meet/Teams create) stays OUTSIDE the
    # transaction — a slow provider must not pin a DB connection. Failure is
    # non-fatal by design: the booking stands, the banner offers a retry.
    conference_error = !attach_conference_link(event)
    @request.sync_message!
    CalendarInviteDispatch.deliver(event, @membership)
    broadcast(event)
    Result.new(event: event, conflict: conflict, conference_error: conference_error)
  end

  def decline(reason)
    decided = @request.with_lock do
      next false if @request.expire_if_stale!
      next false unless @request.pending?

      @request.update!(status: MeetingRequest::STATUS_DECLINED, decline_reason: reason.to_s.strip.presence)
      true
    end
    return nil unless decided

    @request.sync_message!
    MeetMailerService.request_declined(@request)
    Result.new(event: nil, conflict: false, conference_error: false)
  end

  private

  def create_event
    calendar = Calendar.primary_for(@link.organization, @membership)
    event = calendar.calendar_events.create!(
      organization: @link.organization,
      created_by_membership: @membership,
      title: "#{@link.label} — #{@request.name}",
      description: description,
      start_at: @request.start_at,
      end_at: @request.end_at,
      timezone: @membership.user&.default_timezone.presence || "UTC",
      status: CalendarEvent::STATUS_CONFIRMED,
      organizer_email: @membership.primary_email_address,
      organizer_name: @membership.user&.display_name
    )
    # The visitor asked for this exact slot; they arrive pre-accepted.
    event.attendees.create!(
      email: @request.email,
      name: @request.name,
      response_status: CalendarAttendee::RESPONSE_ACCEPTED
    )
    event
  end

  def description
    lines = ["Requested via meet link \"#{@link.label}\" by #{@request.name} <#{@request.email}>."]
    lines << "" << @request.note if @request.note.present?
    lines.join("\n")
  end

  # Generate the Meet/Teams link when the meet link asks for one and the
  # invitee has the matching conferencing connection. Never blocks the accept:
  # a failed generation is reported and retriable, the booking stands.
  # Returns true when nothing was needed or the link was attached.
  def attach_conference_link(event)
    provider = ConferenceLink::PROVIDER_FOR_MODE[@link.conference_mode]
    return true if provider.nil?

    connection = ConferencingConnection.find_by(membership: @membership, provider: provider)
    return false if connection.nil?

    url = ConferenceLink.generate(
      connection,
      subject: event.title,
      start_at: event.start_at,
      end_at: event.end_at
    )
    return false if url.blank?

    event.update!(location: url)
    true
  end

  def broadcast(event)
    org = @link.organization
    if @request.message
      ActionCable.server.broadcast(
        "organization_#{org.key}",
        { type: "meeting_request_decided", message_id: @request.message.key, status: @request.status }
      )
    end
    if event
      ActionCable.server.broadcast("calendar_#{org.key}", { type: "event_created", event_id: event.key })
    end
  rescue StandardError => e
    Rails.logger.warn("[MeetingRequestDecision] broadcast failed: #{e.message}")
  end
end
