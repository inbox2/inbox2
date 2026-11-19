require "rails_helper"

# MX-operational behaviors layered onto the inbound pipeline: receiving_mail
# promotion and DSN/ARF report short-circuiting.
RSpec.describe InboundMailProcessor, "MX behaviors" do
  let(:owner) { create(:user, username: "mx_inbound_owner") }
  let(:org) { create(:organization, owner: owner, domain: "acme.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

  def base_payload(overrides = {})
    {
      "envelope" => { "mail_from" => "sender@example.com", "rcpt_to" => ["support@acme.com"], "client_ip" => "203.0.113.1" },
      "headers" => { "from" => "Alice <sender@example.com>", "to" => "support@acme.com", "subject" => "Hi", "content_type" => "text/plain", "message_id" => "<m-#{SecureRandom.hex(3)}@example.com>" },
      "body" => { "plain" => "Hello", "html" => "" },
      "attachments" => [],
      "authentication" => { "dmarc" => { "result" => "pass", "policy" => "none" } },
      "raw_message_b64" => ""
    }.deep_merge(overrides)
  end

  describe "receiving_mail promotion" do
    it "promotes a verified domain to receiving_mail on first real mail" do
      expect { described_class.new(base_payload).process }
        .to change { org.default_domain.reload.status }
        .from(Domain::STATUS_VERIFIED)
        .to(Domain::STATUS_RECEIVING_MAIL)
    end

    it "leaves an already-receiving domain untouched" do
      org.default_domain.update!(status: Domain::STATUS_RECEIVING_MAIL)
      described_class.new(base_payload).process
      expect(org.default_domain.reload.status).to eq(Domain::STATUS_RECEIVING_MAIL)
    end
  end

  describe "idempotency (at-least-once redelivery)" do
    it "does not create a duplicate message when the same Message-ID is redelivered" do
      payload = base_payload("headers" => { "message_id" => "<dup-1@example.com>" })

      first = described_class.new(payload).process
      expect(first[:message]).to be_present

      expect { described_class.new(payload).process }.not_to change(Message, :count)
      expect(described_class.new(payload).process).to eq(duplicate: true)
    end
  end

  describe "DSN bounce short-circuit" do
    let(:conversation) { create(:conversation, organization: org) }
    let!(:sent) { create(:message, conversation: conversation, organization: org, to_address: "customer@example.com", is_inbound: false) }
    let!(:delivery) { create(:delivery_status, message: sent, status: "sending") }

    let(:dsn) do
      <<~MSG
        From: MAILER-DAEMON@example.com
        To: support@acme.com
        Subject: failure
        Content-Type: multipart/report; report-type=delivery-status; boundary="b"

        --b
        Content-Type: message/delivery-status

        Final-Recipient: rfc822; customer@example.com
        Action: failed
        Status: 5.1.1

        --b--
      MSG
    end

    it "updates delivery tracking and does not thread a conversation" do
      payload = base_payload(
        "headers" => { "content_type" => "multipart/report; report-type=delivery-status" },
        "raw_message_b64" => Base64.strict_encode64(dsn)
      )

      expect { described_class.new(payload).process }.not_to change(Conversation, :count)
      expect(delivery.reload.status).to eq(DeliveryStatus::STATUS_BOUNCED)
      expect(SuppressionEntry.suppressed?(org, "customer@example.com")).to be(true)
    end
  end
end
