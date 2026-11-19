class ViewSerializer < ::ApplicationSerializer
  attributes :name, :kind, :filters, :position, :icon, :created_at
end
