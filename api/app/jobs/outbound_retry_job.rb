# Re-publishes a deferred outbound message to NATS for retry.
# Scheduled by the delivery status consumer when DeliveryRetryService
# determines a transient failure should be retried.
#
# Spec reference: 20.2.3
class OutboundRetryJob < ApplicationJob
  queue_as :default

  def perform(delivery_status_id)
    delivery_status = DeliveryStatus.find(delivery_status_id)
    return unless delivery_status.status == DeliveryStatus::STATUS_DEFERRED

    message = delivery_status.message
    return unless message

    delivery_status.update!(status: DeliveryStatus::STATUS_QUEUED)

    # Reuse the existing DeliveryStatus so attempt history accrues on one record
    # rather than spawning a fresh status per retry.
    OutboundMailPublisher.new(message).publish(delivery_status: delivery_status)
    Rails.logger.info("[OutboundRetryJob] Re-published message #{message.key} for retry (attempt #{delivery_status.attempt_count + 1})")
  rescue => e
    Rails.logger.error("[OutboundRetryJob] Failed to retry #{delivery_status_id}: #{e.message}")
  end
end
