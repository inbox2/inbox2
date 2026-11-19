class EspDeliverySerializer < ApplicationSerializer
  attributes :recipient, :status, :attempt_count, :smtp_code, :response, :mx_host, :delivered_at, :failed_at
end
