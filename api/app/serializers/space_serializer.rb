class SpaceSerializer < ::ApplicationSerializer
  attributes :name, :slug, :icon, :color, :openness, :alias_local, :description, :not_for,
             :classify, :position, :created_at

  # Controller-populated stats (see SpacesController#index). Defaults keep the
  # serializer safe for single-record responses that don't compute counts.
  attribute :open do |space|
    space.stats&.fetch(:open, 0) || 0
  end

  attribute :unread do |space|
    space.stats&.fetch(:unread, 0) || 0
  end

  attribute :volume do |space|
    space.stats&.fetch(:volume, 0) || 0
  end

  attribute :unassigned do |space|
    space.stats&.fetch(:unassigned, 0) || 0
  end

  attribute :members do |space|
    space.member_summaries || []
  end
end
