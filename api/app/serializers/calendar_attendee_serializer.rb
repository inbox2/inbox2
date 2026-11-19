class CalendarAttendeeSerializer < ::ApplicationSerializer
  attributes :email, :name, :response_status, :is_organizer, :is_optional, :responded_at, :comment

  attribute :proposed_start do |attendee|
    attendee.proposed_start
  end

  attribute :proposed_end do |attendee|
    attendee.proposed_end
  end
end
