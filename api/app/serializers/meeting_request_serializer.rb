class MeetingRequestSerializer < ::ApplicationSerializer
  attributes :name, :email, :note, :start_at, :end_at, :visitor_timezone,
             :status, :decline_reason, :created_at

  attribute :meet_link_label do |request|
    request.meet_link.label
  end

  attribute :calendar_event_id do |request|
    request.calendar_event&.key
  end

  attribute :message_id do |request|
    request.message&.key
  end
end
