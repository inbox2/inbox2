# Queues one delivery on NATS for the Go sender: the same MAIL_OUTBOUND job
# inbox2's own mail uses, with the delivery's bounce address as envelope sender.
# The result comes back keyed by the delivery's key (NatsSubscriber).
class Esp::Publisher
  def self.publish(delivery)
    message = delivery.message
    raise "#{message.key} has no stored message (past retention)" if message.raw_mime.blank?

    payload = {
      version: 1,
      delivery_status_id: delivery.id,
      # Echoed back with the result; names the attempt (Esp::Delivery#record_result!).
      delivery_status_key: delivery.attempt_key,
      message_key: message.key,
      envelope: { mail_from: delivery.bounce_address, rcpt_to: [delivery.recipient] },
      # d= is the From domain: that alignment is what passes DMARC, since the
      # envelope sender is on our bounce domain.
      dkim: { domain: message.from_domain, selector: DkimKey.selector, private_key_pem: DkimKey.private_key_pem.to_s },
      channel: { kind: DeliveryChannel::KIND_BUILTIN, delivery_channel_id: 0 },
      rfc5322_b64: Base64.strict_encode64(message.raw_mime)
    }
    OutboundMailPublisher.publish_payload(delivery.recipient.split("@").last.downcase, payload)
    # Marks the claim as handed over: from here only a verdict moves it on.
    delivery.update_columns(published_at: Time.current)
  end
end
