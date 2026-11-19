require "rails_helper"

# Out-of-office auto-replies (docs/Calendar.md).
#
# Most of these are NEGATIVE tests on purpose: answering the wrong thing is how
# an auto-responder turns into a mail loop, so every suppression rule gets its
# own case.
RSpec.describe OutOfOfficeResponder do
  let(:away) { create(:user, username: "awayuser", display_name: "Away User") }
  let(:org) { create(:organization, owner: away, domain: "away.com") }
  let!(:membership) { create(:membership, user: away, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:domain) { org.domains.first }
  let!(:mailbox) { Mailbox.create!(membership: membership, domain: domain, local_part: "awayuser") }

  let(:conversation) { org.conversations.create!(subject: "Hello", status: Conversation::STATUS_OPEN) }

  before do
    away.update!(out_of_office_start: 1.day.ago, out_of_office_end: 5.days.from_now,
                 out_of_office_message: "On holiday until Monday.")
  end

  # A unique Message-ID per call: the real partial unique index on
  # (organization_id, message_id_header) is live in these specs.
  def inbound(from: "sender@example.com", subject: "Hello", **attrs)
    @seq = (@seq || 0) + 1
    conversation.messages.create!({
      organization: org, from_address: from, to_address: "awayuser@away.com",
      subject: subject, message_id_header: "<in-#{@seq}@example.com>",
      is_inbound: true, is_draft: false
    }.merge(attrs))
  end

  def raw(headers = {})
    base = {
      "From" => "sender@example.com", "To" => "awayuser@away.com",
      "Subject" => "Hello", "Message-ID" => "<in-1@example.com>"
    }.merge(headers)
    base.map { |k, v| "#{k}: #{v}" }.join("\r\n") + "\r\n\r\nBody text\r\n"
  end

  def respond(message: nil, raw_mime: nil, envelope: { "mail_from" => "sender@example.com" }, local: "awayuser")
    described_class.maybe_reply(
      organization: org, domain: domain, message: message || inbound,
      envelope: envelope, raw_mime: raw_mime || raw, recipient_local_part: local
    )
  end

  describe "sending" do
    it "replies with the person's own message" do
      reply = respond

      expect(reply).to be_present
      expect(reply.to_address).to eq("sender@example.com")
      expect(reply.from_address).to eq("awayuser@away.com")
      expect(reply.subject).to eq("Automatic reply: Hello")
      expect(reply.body_plain).to eq("On holiday until Monday.")
      expect(reply.is_inbound).to be(false)
    end

    it "marks the reply Auto-Submitted so the far side does not answer it" do
      expect(respond.auto_submitted).to eq(Message::AUTO_SUBMITTED_REPLIED)
    end

    it "puts the RFC 3834 headers on the wire" do
      reply = respond
      mime = OutboundMailPublisher.new(reply).compose_mime

      expect(mime).to include("Auto-Submitted: auto-replied")
      expect(mime).to include("X-Auto-Response-Suppress: All")
      expect(mime).to include("Precedence: auto_reply")
    end

    it "threads onto the message it is answering" do
      msg = inbound
      expect(respond(message: msg).in_reply_to).to eq(msg.message_id_header)
    end

    it "falls back to a default when no message was written" do
      away.update!(out_of_office_message: nil)
      expect(respond.body_plain).to eq(described_class::DEFAULT_MESSAGE)
    end

    it "queues the reply for delivery" do
      expect { respond }.to have_enqueued_job(OutboundDeliveryJob)
    end
  end

  describe "answering each sender only once per absence" do
    it "does not reply twice to the same sender" do
      expect(respond).to be_present
      expect(respond(message: inbound(subject: "Second"))).to be_nil
    end

    it "still replies to a different sender" do
      expect(respond).to be_present
      expect(respond(message: inbound(from: "other@example.com"),
                     raw_mime: raw("From" => "other@example.com"),
                     envelope: { "mail_from" => "other@example.com" })).to be_present
    end

    it "replies again when a NEW absence starts" do
      expect(respond).to be_present

      away.update!(out_of_office_start: 1.hour.ago, out_of_office_end: 3.days.from_now)
      expect(respond(message: inbound(subject: "Next trip"))).to be_present
    end

    it "is safe against a concurrent duplicate delivery" do
      # The unique index, not the check, is what arbitrates.
      expect(OutOfOfficeReply.claim(user: away, organization: org,
                                    sender: "dup@example.com", period_start: away.out_of_office_start)).to be(true)
      expect(OutOfOfficeReply.claim(user: away, organization: org,
                                    sender: "dup@example.com", period_start: away.out_of_office_start)).to be(false)
    end
  end

  describe "never replies to (negative)" do
    it "an Auto-Submitted message" do
      expect(respond(raw_mime: raw("Auto-Submitted" => "auto-generated"))).to be_nil
    end

    it "another auto-reply" do
      expect(respond(raw_mime: raw("Auto-Submitted" => "auto-replied"))).to be_nil
    end

    it "but does reply when Auto-Submitted says a human sent it" do
      expect(respond(raw_mime: raw("Auto-Submitted" => "no"))).to be_present
    end

    it "bulk mail" do
      expect(respond(raw_mime: raw("Precedence" => "bulk"))).to be_nil
    end

    it "a mailing list" do
      expect(respond(raw_mime: raw("List-Id" => "<dev.example.com>"))).to be_nil
      expect(respond(raw_mime: raw("List-Unsubscribe" => "<mailto:x@y.com>"))).to be_nil
    end

    it "a sender asking for suppression" do
      expect(respond(raw_mime: raw("X-Auto-Response-Suppress" => "OOF"))).to be_nil
      expect(respond(raw_mime: raw("X-Auto-Response-Suppress" => "All"))).to be_nil
    end

    it "a bounce with an empty envelope sender" do
      expect(respond(envelope: { "mail_from" => "" })).to be_nil
      expect(respond(envelope: { "mail_from" => "<>" })).to be_nil
    end

    it "a robot address" do
      %w[mailer-daemon@x.com no-reply@x.com noreply@x.com postmaster@x.com bounces@x.com].each do |addr|
        expect(respond(message: inbound(from: addr),
                       raw_mime: raw("From" => addr),
                       envelope: { "mail_from" => addr })).to be_nil
      end
    end

    it "itself" do
      expect(respond(message: inbound(from: "awayuser@away.com"),
                     raw_mime: raw("From" => "awayuser@away.com"),
                     envelope: { "mail_from" => "awayuser@away.com" })).to be_nil
    end

    it "spam" do
      expect(respond(message: inbound(spam_action: "reject"))).to be_nil
    end

    it "mail for somebody who is not away" do
      away.update!(out_of_office_start: nil, out_of_office_end: nil)
      expect(respond).to be_nil
    end

    it "mail arriving outside the absence" do
      away.update!(out_of_office_start: 10.days.from_now, out_of_office_end: 12.days.from_now)
      expect(respond).to be_nil
    end

    it "mail for a local part with no mailbox" do
      expect(respond(local: "nobody")).to be_nil
    end
  end

  describe "resilience" do
    it "never raises when the raw source is unparseable" do
      expect { respond(raw_mime: "\xC3\x28 not a mime document") }.not_to raise_error
    end

    it "still replies when there is no raw source at all" do
      # Nothing to suppress on, but the mail is still real and the person away.
      expect(respond(raw_mime: nil)).to be_present
    end
  end
end
