require "rails_helper"

RSpec.describe InboundReportRouter do
  let(:owner) { create(:user, username: "reportowner") }
  let(:org) { create(:organization, owner: owner, domain: "acme.com") }

  def dsn_message(status:, final_rcpt:, message_id: "<orig-1@acme.com>")
    <<~MSG
      From: MAILER-DAEMON@mail.example.com
      To: support@acme.com
      Subject: Delivery Status Notification (Failure)
      Content-Type: multipart/report; report-type=delivery-status; boundary="b"

      --b
      Content-Type: text/plain

      Your message could not be delivered.

      --b
      Content-Type: message/delivery-status

      Reporting-MTA: dns; mail.example.com
      Final-Recipient: rfc822; #{final_rcpt}
      Action: failed
      Status: #{status}
      Diagnostic-Code: smtp; 550 #{status} user unknown

      --b
      Content-Type: message/rfc822

      To: #{final_rcpt}
      Message-ID: #{message_id}
      Subject: Re: hi

      body
      --b--
    MSG
  end

  def arf_message(complainer:)
    <<~MSG
      From: fbl@isp.example
      To: support@acme.com
      Subject: complaint
      Content-Type: multipart/report; report-type=feedback-report; boundary="b"

      --b
      Content-Type: text/plain

      This is an abuse complaint.

      --b
      Content-Type: message/feedback-report

      Feedback-Type: abuse
      User-Agent: SomeFBL/1.0
      Original-Rcpt-To: #{complainer}

      --b--
    MSG
  end

  describe "#route — DSN bounce" do
    let(:conversation) { create(:conversation, organization: org) }
    let!(:message) do
      create(:message, conversation: conversation, organization: org,
             to_address: "customer@example.com", is_inbound: false,
             message_id_header: "<orig-1@acme.com>")
    end
    let!(:delivery) { create(:delivery_status, message: message, status: "sending") }

    it "updates the originating delivery status and suppresses a hard bounce" do
      raw = dsn_message(status: "5.1.1", final_rcpt: "customer@example.com")
      result = described_class.new(org, raw, content_type_hint: "multipart/report; report-type=delivery-status").route

      expect(result).to eq(:bounce)
      expect(delivery.reload.status).to eq(DeliveryStatus::STATUS_BOUNCED)
      expect(delivery.bounce_type).to eq("hard")
      expect(SuppressionEntry.suppressed?(org, "customer@example.com")).to be(true)
    end

    it "does not suppress a transient (4xx) bounce" do
      raw = dsn_message(status: "4.2.2", final_rcpt: "customer@example.com")
      result = described_class.new(org, raw, content_type_hint: "multipart/report; report-type=delivery-status").route

      expect(result).to eq(:bounce)
      expect(SuppressionEntry.suppressed?(org, "customer@example.com")).to be(false)
    end
  end

  describe "#route — ARF complaint" do
    it "suppresses the complaining recipient" do
      raw = arf_message(complainer: "angry@example.com")
      result = described_class.new(org, raw, content_type_hint: "multipart/report; report-type=feedback-report").route

      expect(result).to eq(:complaint)
      entry = SuppressionEntry.find_by(organization: org, address: "angry@example.com")
      expect(entry).to be_present
      expect(entry.reason).to eq(SuppressionEntry::REASON_COMPLAINT)
    end
  end

  describe "#route — ordinary mail" do
    it "returns nil so the caller threads it normally" do
      raw = "From: a@b.com\r\nTo: support@acme.com\r\nSubject: hi\r\n\r\nhello"
      expect(described_class.new(org, raw, content_type_hint: "text/plain").route).to be_nil
    end
  end
end
