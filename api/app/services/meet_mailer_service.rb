# The visitor-facing meet-link emails (docs/Calendar.md): "request received"
# when they ask for a slot, "declined" when the invitee says no. An ACCEPT
# needs no mail from here — the real calendar invite (CalendarInviteDispatch)
# IS the answer. Same delivery path as the waitlist mails: in-repo ERB, sent
# raw through Messy off the request thread.
class MeetMailerService
  def self.request_received(request)
    deliver(request, "request_received", "Meeting request sent — awaiting confirmation")
  end

  def self.request_declined(request)
    deliver(request, "request_declined", "About your meeting request")
  end

  def self.deliver(request, template, subject)
    body = render(template,
      request: request,
      invitee_name: request.meet_link.invitee_membership.user&.then { |u| u.display_name.presence || u.username } || "the organizer",
      when_lines: when_lines(request))
    MessyTriggerJob.perform_later("send_message", to: request.email, subject: subject, body: body)
  end
  private_class_method :deliver

  # The slot in the invitee's timezone and — when different — the visitor's own.
  def self.when_lines(request)
    invitee_tz = MeetAvailability.new(request.meet_link, request.start_at, request.end_at).timezone
    zones = [invitee_tz, request.visitor_timezone].compact.uniq
    zones.filter_map do |tz|
      zone = Time.find_zone(tz)
      next nil unless zone

      start = request.start_at.in_time_zone(zone)
      finish = request.end_at.in_time_zone(zone)
      "#{start.strftime('%a %-d %b %Y, %H:%M')}–#{finish.strftime('%H:%M')} (#{zone.name})"
    end
  end

  def self.render(template, **locals)
    ApplicationController.renderer.render(
      template: "meet_mailer/#{template}",
      formats: [:html],
      layout: false,
      locals: locals
    )
  end
  private_class_method :render
end
