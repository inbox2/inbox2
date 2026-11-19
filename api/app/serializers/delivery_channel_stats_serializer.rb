class DeliveryChannelStatsSerializer
  include Alba::Resource

  attribute :channel_id do |channel|
    channel.key
  end

  attribute :total do |channel|
    channel.delivery_statuses.count
  end

  attribute :delivered do |channel|
    channel.delivery_statuses.where(status: DeliveryStatus::STATUS_DELIVERED).count
  end

  attribute :failed do |channel|
    channel.delivery_statuses.where(status: DeliveryStatus::STATUS_FAILED).count
  end

  attribute :bounced do |channel|
    channel.delivery_statuses.where(status: DeliveryStatus::STATUS_BOUNCED).count
  end
end
