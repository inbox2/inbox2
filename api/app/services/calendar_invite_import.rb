# Puts an accepted email invitation onto the member's own calendar
# (docs/Calendar.md). Answering the organizer and having the meeting show up in
# your week are two different things: until this existed, MX stored the invite
# on the message, emailed a REPLY, and the event never appeared anywhere.
#
# Idempotent on ical_uid, so a re-sent invitation (same UID, higher SEQUENCE)
# updates the existing row instead of stacking duplicates.
class CalendarInviteImport
  def self.apply(organization, membership, invite, response)
    new(organization, membership, invite, response).apply
  end

  def initialize(organization, membership, invite, response)
    @organization = organization
    @membership = membership
    @invite = invite || {}
    @response = response.to_s
  end

  # Returns the CalendarEvent, or nil when there is nothing to place.
  def apply
    return nil if uid.blank? || starts_at.blank?

    # An invitation from a colleague is already the org's own event, and the
    # guest can see it through CalendarEvent.visible_to. Copying it here would
    # put the same meeting on the calendar twice and split the RSVP across two
    # rows — so answer the original instead.
    if (shared = internal_event)
      answer_on(shared)
      return @response == CalendarAttendee::RESPONSE_DECLINED ? nil : shared
    end

    return decline! if @response == CalendarAttendee::RESPONSE_DECLINED

    event = upsert_event
    record_self_as_attendee(event)
    event
  end

  private

  # An event already in this org carrying the invitation's UID — i.e. one we
  # sent ourselves. Excludes anything already imported onto our own calendar,
  # which is a copy, not the original.
  def internal_event
    return nil if @membership.nil?

    @organization.calendar_events
      .where(ical_uid: uid)
      .where.not(calendar_id: calendar.id)
      .first
  end

  def answer_on(event)
    email = @membership.primary_email_address
    return if email.blank?

    attendee = event.attendees.where("LOWER(email) = ?", email.downcase).first ||
      event.attendees.build(email: email)
    attendee.response_status = @response
    attendee.responded_at = Time.current
    attendee.save!
  end

  def uid
    @invite["uid"].presence
  end

  def starts_at
    @starts_at ||= parse_time(@invite["start"])
  end

  def ends_at
    # A missing DTEND is legal; default to an hour so the row passes validation
    # rather than dropping the invite on the floor.
    parse_time(@invite["end"]) || (starts_at + 1.hour)
  end

  def parse_time(value)
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  # Declining removes our copy — but only the copy we imported onto this
  # member's own calendar. An event someone else in the org organizes has a
  # different origin and is left alone.
  def decline!
    existing&.destroy
    nil
  end

  def existing
    @existing ||= calendar.calendar_events.find_by(ical_uid: uid)
  end

  def calendar
    @calendar ||= Calendar.primary_for(@organization, @membership)
  end

  def upsert_event
    event = existing || calendar.calendar_events.new(ical_uid: uid)
    event.assign_attributes(
      organization: @organization,
      created_by_membership: @membership,
      title: @invite["summary"].presence || "(No title)",
      description: @invite["description"],
      location: @invite["location"],
      start_at: starts_at,
      end_at: ends_at,
      all_day: !!@invite["all_day"],
      timezone: @invite["timezone"].presence || "UTC",
      recurrence_rule: @invite["rrule"].presence,
      organizer_email: @invite["organizer_email"],
      organizer_name: @invite["organizer_name"],
      sequence: @invite["sequence"].to_i,
      status: status_for_response
    )
    event.save!
    event
  end

  def status_for_response
    @response == CalendarAttendee::RESPONSE_TENTATIVE ? CalendarEvent::STATUS_TENTATIVE : CalendarEvent::STATUS_CONFIRMED
  end

  # Mirrors the answer we mailed the organizer onto the local attendee list, so
  # the event shows our own response and free/busy counts it.
  def record_self_as_attendee(event)
    invited = Array(@invite["attendees"]).filter_map { |a| a["email"].presence }
    (invited + [@membership&.primary_email_address]).compact.uniq.each do |email|
      attendee = event.attendees.where("LOWER(email) = ?", email.downcase).first ||
        event.attendees.build(email: email)
      attendee.is_organizer = email.casecmp?(@invite["organizer_email"].to_s)
      attendee.response_status = @response if email.casecmp?(@membership&.primary_email_address.to_s)
      attendee.responded_at = Time.current if attendee.response_status == @response
      attendee.save!
    end
  end
end
