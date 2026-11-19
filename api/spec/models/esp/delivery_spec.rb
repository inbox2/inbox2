require "rails_helper"

# E1 mapping: spec 21.3 — ESP delivery results, bounces and events (docs/ESP.md)
RSpec.describe Esp::Delivery do
  let(:delivery) { create(:esp_delivery) }
  let(:org) { delivery.organization }

  # One attempt as the pipeline runs it: claimed by the job, then its verdict.
  def attempt!(**result)
    expect(delivery.claim!).to be_truthy
    delivery.record_result!(attempt: delivery.attempt_count + 1, **result)
  end

  it "marks a delivered attempt and records the event (21.3.1)" do
    expect(attempt!(result: "success", smtp_code: "250", response: "2.0.0 OK", mx_host: "mx.example")).to be_nil
    expect(delivery.reload.status).to eq("delivered")
    expect(delivery.events.pluck(:kind)).to eq(["delivered"])
  end

  it "bounces and suppresses an address the remote says does not exist (21.3.2)" do
    attempt!(result: "permanent_failure", smtp_code: "550", enhanced_code: "5.1.1", response: "no such user")
    expect(delivery.reload.status).to eq("bounced")
    expect(SuppressionEntry.suppressed?(org, delivery.recipient)).to be(true)
  end

  it "does not suppress on a content rejection" do
    attempt!(result: "permanent_failure", smtp_code: "554", enhanced_code: "5.7.1", response: "spam")
    expect(SuppressionEntry.suppressed?(org, delivery.recipient)).to be(false)
  end

  it "defers with a growing delay, then fails after the last retry (21.3.3)" do
    delays = Array.new(DeliveryRetryService::MAX_RETRIES - 1) { attempt!(result: "transient_failure", smtp_code: "451") }
    expect(delays).to eq([120, 240, 480, 960])
    expect(delivery.reload.status).to eq("deferred")
    expect(attempt!(result: "transient_failure", smtp_code: "451")).to be_nil
    expect(delivery.reload.status).to eq("failed")
  end

  it "counts a verdict once: a repeated or late one changes nothing (21.3.7)" do
    attempt!(result: "transient_failure", smtp_code: "451")
    # NATS redelivers the same verdict; the delivery is deferred and unclaimed.
    expect(delivery.record_result!(attempt: 1, result: "transient_failure")).to be_nil
    expect(delivery.reload.attempt_count).to eq(1)

    # Attempt 2 is in flight when a late copy of attempt 1's verdict arrives.
    delivery.claim!
    expect(delivery.record_result!(attempt: 1, result: "permanent_failure", smtp_code: "550")).to be_nil
    expect(delivery.reload.status).to eq("sending")

    delivery.record_result!(attempt: 2, result: "success")
    expect(delivery.record_result!(attempt: 2, result: "permanent_failure", smtp_code: "550")).to be_nil
    expect(delivery.reload.status).to eq("delivered")
  end

  it "lets one job publish a delivery however many are queued for it (21.3.8)" do
    published = 0
    allow(Esp::Publisher).to receive(:publish) { published += 1 }
    2.times { Esp::DeliverJob.perform_now(delivery.id) }
    expect(published).to eq(1)

    # A failed publish gives the delivery back, and the sweeper queues it again.
    other = create(:esp_delivery)
    allow(Esp::Publisher).to receive(:publish).and_raise("nats down")
    expect { Esp::DeliverJob.perform_now(other.id) }.to raise_error("nats down")
    expect(other.reload).to have_attributes(status: "queued", published_at: nil)
    other.update_column(:updated_at, 1.hour.ago)
    expect { Esp::RequeueJob.perform_now }.to have_enqueued_job(Esp::DeliverJob).with(other.id)
  end

  it "recovers a delivery whose job died after the claim, and one that never got a verdict (21.3.8)" do
    died = create(:esp_delivery).tap(&:claim!)
    died.update_column(:updated_at, 30.minutes.ago)
    in_flight = create(:esp_delivery).tap(&:claim!)
    in_flight.update_columns(published_at: 5.minutes.ago, updated_at: 30.minutes.ago)
    lost = create(:esp_delivery).tap(&:claim!)
    lost.update_columns(published_at: 4.days.ago)

    expect { Esp::RequeueJob.perform_now }.to have_enqueued_job(Esp::DeliverJob).once.with(died.id)
    expect(died.reload.status).to eq("queued")
    expect(in_flight.reload.status).to eq("sending") # published: only a verdict may move it
    expect(lost.reload.status).to eq("failed")
  end

  it "tells only the webhooks subscribed to the event (21.3.4)" do
    subscribed = org.webhooks.create!(url: "https://hooks.example/a", events: ["email.delivered"])
    org.webhooks.create!(url: "https://hooks.example/b", events: ["email.bounced"])
    expect { attempt!(result: "success") }
      .to have_enqueued_job(EspWebhookJob).once.with(subscribed.id, kind_of(Integer))
  end

  describe Esp::BounceProcessor do
    def dsn(status)
      <<~MIME.gsub("\n", "\r\n")
        From: MAILER-DAEMON@mx.example
        To: #{delivery.bounce_address}
        Subject: Undelivered Mail
        MIME-Version: 1.0
        Content-Type: multipart/report; report-type=delivery-status; boundary="b"

        --b
        Content-Type: text/plain

        It bounced.
        --b
        Content-Type: message/delivery-status

        Reporting-MTA: dns; mx.example

        Final-Recipient: rfc822; #{delivery.recipient}
        Action: failed
        Status: #{status}
        Diagnostic-Code: smtp; 550 #{status} mailbox unavailable
        --b--
      MIME
    end

    def payload(raw, rcpt: delivery.bounce_address)
      { "envelope" => { "rcpt_to" => [rcpt] }, "raw_message_b64" => Base64.strict_encode64(raw) }
    end

    it "settles the delivery a later bounce names, through the inbound pipeline (21.3.5)" do
      attempt!(result: "success")
      expect(InboundMailProcessor.new(payload(dsn("5.1.1"))).process).to eq({ report: :bounce })
      expect(delivery.reload.status).to eq("bounced")
      expect(SuppressionEntry.suppressed?(org, delivery.recipient)).to be(true)
      expect(Conversation.count).to eq(0)
    end

    it "ignores other mail sent to a bounce address, and unknown tokens" do
      expect(described_class.new(payload("Subject: Out of office\r\n\r\nBack Monday\r\n")).process).to eq(:ignored)
      expect(described_class.new(payload(dsn("5.1.1"), rcpt: "b+nope@#{Esp::BOUNCE_DOMAIN}")).process).to eq(:unknown)
      expect(delivery.reload.status).to eq("queued")
    end
  end

  describe Esp::Publisher do
    it "queues the stored message with the bounce address as envelope sender (21.3.6)" do
      sent = nil
      allow(OutboundMailPublisher).to receive(:publish_payload) { |dest, payload| sent = [dest, payload] }
      described_class.publish(delivery)
      dest, payload = sent
      expect(dest).to eq("example.com")
      expect(payload[:delivery_status_key]).to eq("#{delivery.key}:1")
      expect(payload[:envelope]).to eq(mail_from: delivery.bounce_address, rcpt_to: [delivery.recipient])
      expect(payload[:dkim][:domain]).to eq("org.test")
      expect(Base64.decode64(payload[:rfc5322_b64])).to eq(delivery.message.raw_mime)
      expect(delivery.reload.published_at).to be_present
    end
  end
end
