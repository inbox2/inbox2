class CalendarSerializer < ::ApplicationSerializer
  attributes :name, :description, :color, :source, :is_primary, :is_visible, :status, :last_synced_at, :created_at, :updated_at

  attribute :membership_id do |calendar|
    calendar.membership&.key
  end
end
