class CalendarEventSerializer < ::ApplicationSerializer
  attributes :title, :description, :location, :start_at, :end_at, :all_day, :timezone,
             :status, :visibility, :ical_uid, :sequence, :recurrence_rule,
             :organizer_email, :organizer_name, :conversation_key, :created_at, :updated_at

  # One generated instance of a repeating series is addressed as
  # "<series key>@<occurrence start>" — the id the client sends back to edit,
  # delete or RSVP to that single instance. Persisted rows keep their plain key.
  attribute :id do |event|
    event.occurrence_id
  end

  # The series this row belongs to, for clients that want to offer
  # "this / following / all" on a recurring event.
  attribute :series_id do |event|
    event.occurrence_start.present? ? event.key : event.recurring_event_key
  end

  attribute :is_recurring do |event|
    event.recurrence_rule.present? || event.occurrence_start.present? || event.recurring_event_key.present?
  end

  # The series' rule, for the editor to prefill a series edit with. An edited
  # instance (exception row) carries none of its own, so it reads the master's.
  # ponytail: one lookup per exception row in a page; exceptions are rare —
  # preload masters if a calendar with many shows up in a profile.
  attribute :series_rule do |event|
    event.recurrence_rule.presence ||
      (event.recurring_event_key.presence &&
        CalendarEvent.where(calendar_id: event.calendar_id, key: event.recurring_event_key).pick(:recurrence_rule))
  end

  attribute :calendar_id do |event|
    event.calendar.key
  end

  attribute :recurring_event_id do |event|
    event.recurring_event_key
  end

  attribute :original_start_at do |event|
    event.original_start_at
  end

  # Your own event vs an invite you accepted — the client offers to decline to
  # the organizer when an invite is deleted. nil when the caller passed no member.
  attribute :organized_by_me do |event|
    params[:my_addresses] && event.organized_by?(params[:my_addresses])
  end

  many :attendees, serializer: CalendarAttendeeSerializer
  many :reminders, serializer: CalendarReminderSerializer
end
