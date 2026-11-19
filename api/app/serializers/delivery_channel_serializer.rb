class DeliveryChannelSerializer < ::ApplicationSerializer
  attributes :name, :kind, :status, :is_default, :created_at
end
