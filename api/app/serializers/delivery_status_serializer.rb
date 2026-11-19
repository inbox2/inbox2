class DeliveryStatusSerializer < ::ApplicationSerializer
  attributes :status, :attempt_count, :delivered_at, :failed_at, :created_at,
             :destination, :recipients, :published_at

  many :delivery_attempts, serializer: DeliveryAttemptSerializer
end
