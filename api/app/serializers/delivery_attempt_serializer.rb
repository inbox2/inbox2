class DeliveryAttemptSerializer < ::ApplicationSerializer
  attributes :attempt_number, :smtp_response_code, :enhanced_status_code,
             :response_message, :result, :created_at
end
