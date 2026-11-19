class BlockedTimeSerializer < ::ApplicationSerializer
  attributes :start_at, :end_at, :created_at
end
