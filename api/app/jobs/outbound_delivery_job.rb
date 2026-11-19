# Publishes a newly-created outbound message to NATS for SMTP delivery.
#
# Enqueued by MessagesController#create so a NATS hiccup doesn't fail the
# HTTP request. Once published, delivery status tracking and transient-failure
# retries are handled downstream by the Go sender + DeliveryRetryService.
#
# Spec reference: 20.2.1
class OutboundDeliveryJob < ApplicationJob
  queue_as :default

  # Transient publish failures (e.g. NATS briefly unreachable) are retried;
  # the message stays undelivered until a publish succeeds.
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message
    return if message.is_draft? || message.is_inbound?

    # Idempotency: skip only destinations that actually reached the queue. A row
    # exists before the publish is attempted, so guarding on presence alone made
    # a failed publish look done — the retry returned early, nothing landed in
    # failed jobs, and the message sat at "queued" forever (prod, 2026-09-09).
    return if message.delivery_statuses.any? && message.delivery_statuses.all?(&:published?)

    OutboundMailPublisher.new(message).publish
    Rails.logger.info("[OutboundDeliveryJob] Published message #{message.key} for delivery")
  end
end
