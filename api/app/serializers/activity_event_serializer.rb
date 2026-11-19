class ActivityEventSerializer < ::ApplicationSerializer
  attributes :action, :metadata, :created_at
end
