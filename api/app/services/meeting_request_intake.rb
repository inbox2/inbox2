# Turns a visitor's slot pick into a MeetingRequest + the inbox message that
# renders the Accept/Decline banner in the invitee's inbox (docs/Calendar.md).
# Nothing touches any calendar here — that is the whole point.
class MeetingRequestIntake
  SLOT_ALIGN_MINUTES = 15

  Result = Struct.new(:request, :errors, keyword_init: true) do
    def ok? = errors.empty?
  end

  def self.call(link, params)
    new(link, params).call
  end

  def initialize(link, params)
    @link = link
    @params = params
  end

  def call
    errors = validate
    return Result.new(request: nil, errors: errors) if errors.any?

    request = nil
    ActiveRecord::Base.transaction do
      request = @link.meeting_requests.create!(
        organization: @link.organization,
        name: @name,
        email: @email,
        note: @params[:note].to_s.strip.presence,
        start_at: @start_at,
        end_at: @end_at,
        visitor_timezone: safe_timezone
      )
      request.update!(message: create_inbox_message(request))
      MeetLink.update_counters(@link.id, requests_count: 1)
    end

    announce(request)
    Result.new(request: request, errors: [])
  end

  private

  def validate
    errors = []
    @name = @params[:name].to_s.strip
    @email = @params[:email].to_s.strip.downcase
    errors << "Name can't be blank" if @name.blank?
    errors << "Email is invalid" unless @email.match?(URI::MailTo::EMAIL_REGEXP)

    @start_at = Time.iso8601(@params[:start_at].to_s) rescue nil
    if @start_at.nil? || @start_at.to_i % (SLOT_ALIGN_MINUTES * 60) != 0
      errors << "Pick a time on the schedule"
      return errors
    end
    @end_at = @start_at + @link.duration_minutes.minutes

    if invitee_address.blank?
      errors << "This link is not accepting requests"
    elsif !availability.bookable?(@start_at, @end_at)
      errors << "That time is no longer available — pick another slot"
    end
    errors
  end

  def availability
    @availability ||= MeetAvailability.new(@link, @start_at, @end_at)
  end

  # Only store a timezone the server can actually resolve — this string is
  # rendered back in mails and banners.
  def safe_timezone
    tz = @params[:timezone].to_s
    Time.find_zone(tz) ? tz : nil
  end

  def invitee_mailbox
    @invitee_mailbox ||= @link.invitee_membership.mailboxes.includes(:domain)
      .min_by { |m| m.domain&.created_at || Time.at(0) }
  end

  def invitee_address = invitee_mailbox&.email_address

  # An ordinary inbound message in the org pool, addressed to the invitee, with
  # the banner payload on the row — the same shape `calendar_invite` uses, so
  # every client that renders messages can render the request.
  def create_inbox_message(request)
    conversation = @link.organization.conversations.create!(
      domain: invitee_mailbox.domain,
      subject: subject,
      from_address: @email,
      to_address: invitee_address,
      status: Conversation::STATUS_OPEN
    )
    message = conversation.messages.create!(
      organization: @link.organization,
      from_address: @email,
      to_address: invitee_address,
      subject: subject,
      body_plain: body(request),
      content_type: "text/plain",
      is_inbound: true,
      is_draft: false,
      meeting_request: request.banner_payload
    )
    # The denormalized list-row preview the inbound processor would have set.
    conversation.update!(snippet: SnippetBuilder.build(message.body_plain, nil))
    message
  end

  def subject
    "Meeting request from #{@name}"
  end

  def body(request)
    zone = Time.find_zone(availability.timezone) || Time.find_zone("UTC")
    lines = []
    lines << "#{@name} <#{@email}> requests a #{@link.duration_minutes}-minute meeting via your meet link \"#{@link.label}\"."
    lines << ""
    lines << "When: #{@start_at.in_time_zone(zone).strftime('%a %-d %b %Y, %H:%M')}–#{@end_at.in_time_zone(zone).strftime('%H:%M')} (#{zone.name})"
    if request.visitor_timezone.present? && request.visitor_timezone != zone.name
      vzone = Time.find_zone(request.visitor_timezone)
      lines << "Their time: #{@start_at.in_time_zone(vzone).strftime('%H:%M')}–#{@end_at.in_time_zone(vzone).strftime('%H:%M')} (#{vzone.name})"
    end
    lines << ""
    lines << request.note if request.note.present?
    lines << ""
    lines << "Accept to add it to your calendar. #{@name} then gets a calendar invite."
    lines.join("\n")
  end

  def announce(request)
    message = request.message
    conversation = message.conversation
    ActionCable.server.broadcast(
      "organization_#{@link.organization.key}",
      { type: "new_message", conversation_id: conversation.key, message_id: message.key }
    )
    MobilePushSender.notify_new_message(@link.organization, conversation, message)
    MeetMailerService.request_received(request)
  rescue StandardError => e
    # The request is stored and visible; a failed side-channel must not 500 the visitor.
    Rails.logger.warn("[MeetingRequestIntake] announce failed: #{e.class}: #{e.message}")
  end
end
