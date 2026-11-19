require "rails_helper"

RSpec.describe InboundMailProcessor do
  let(:owner) { create(:user, username: "inbound_owner") }
  let(:org) { create(:organization, owner: owner, domain: "acme.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

  def build_payload(overrides = {})
    {
      "version" => 1,
      "received_at" => Time.current.iso8601,
      "envelope" => {
        "mail_from" => "sender@example.com",
        "rcpt_to" => ["support@acme.com"],
        "client_ip" => "203.0.113.42",
        "helo_domain" => "mail.example.com"
      },
      "headers" => {
        "message_id" => "<test-#{SecureRandom.hex(4)}@example.com>",
        "in_reply_to" => "",
        "references" => "",
        "from" => "Alice Sender <sender@example.com>",
        "to" => "support@acme.com",
        "cc" => "",
        "subject" => "Test inbound message",
        "date" => Time.current.rfc2822,
        "content_type" => "text/plain"
      },
      "body" => {
        "plain" => "Hello, this is a test message.",
        "html" => ""
      },
      "attachments" => [],
      "authentication" => {
        "spf" => { "result" => "pass", "domain" => "example.com" },
        "dkim" => { "result" => "pass", "domain" => "example.com" },
        "dmarc" => { "result" => "pass", "domain" => "example.com", "policy" => "none" }
      },
      "raw_size_bytes" => 1024,
      "raw_message_b64" => ""
    }.deep_merge(overrides)
  end

  # A raw MIME message carrying an .ics part. MX parses the invite from the RAW
  # message, not the attachment list, because a bare text/calendar part with no
  # Content-Disposition never becomes an attachment row.
  def raw_with_ics(ics)
    raw = <<~MIME
      From: Alice Sender <sender@example.com>
      To: support@acme.com
      Subject: Your appointment
      Content-Type: multipart/mixed; boundary="b1"

      --b1
      Content-Type: text/plain

      See attached.
      --b1
      Content-Type: text/calendar; charset=utf-8

      #{ics}
      --b1--
    MIME
    Base64.strict_encode64(raw.gsub("\n", "\r\n"))
  end

  # docs/Meeting-Invites.md — an ICS is either an invitation to answer or an event
  # to file, and MX used to drop the second kind entirely.
  describe "storing an emailed event" do
    def ics(method_line, uid)
      [
        "BEGIN:VCALENDAR", "VERSION:2.0", method_line, "BEGIN:VEVENT",
        "UID:#{uid}", "SUMMARY:Haircut", "DTSTART:20260916T100000Z",
        "DTEND:20260916T110000Z", "ORGANIZER:mailto:shop@example.com",
        "END:VEVENT", "END:VCALENDAR"
      ].compact.join("\r\n")
    end

    it "stores a REQUEST as an answerable invite" do
      described_class.new(build_payload("raw_message_b64" => raw_with_ics(ics("METHOD:REQUEST", "req-1")))).process
      msg = Message.last
      expect(msg.calendar_invite["method"]).to eq(Message::CALENDAR_METHOD_REQUEST)
      expect(msg.rsvp_status).to eq("needs_action")
    end

    # The appointment-confirmation case: it used to be dropped, leaving the client
    # nothing to render.
    it "stores a PUBLISH with no RSVP slot, so the client offers Add to calendar" do
      described_class.new(build_payload("raw_message_b64" => raw_with_ics(ics("METHOD:PUBLISH", "pub-1")))).process
      msg = Message.last
      expect(msg.calendar_invite["method"]).to eq(Message::CALENDAR_METHOD_PUBLISH)
      expect(msg.calendar_invite["uid"]).to eq("pub-1")
      expect(msg.rsvp_status).to be_nil
    end

    # RFC 5545: METHOD is what makes an iCalendar object a scheduling message, so a
    # VEVENT without one is not asking for anything.
    it "treats a METHOD-less VEVENT as PUBLISH" do
      described_class.new(build_payload("raw_message_b64" => raw_with_ics(ics(nil, "bare-1")))).process
      msg = Message.last
      expect(msg.calendar_invite["method"]).to eq(Message::CALENDAR_METHOD_PUBLISH)
      expect(msg.rsvp_status).to be_nil
    end
  end

  describe "#process" do
    context "new conversation (spec 3.1.3)" do
      it "creates a conversation and message for a new inbound email" do
        payload = build_payload

        expect { described_class.new(payload).process }
          .to change(Conversation, :count).by(1)
          .and change(Message, :count).by(1)

        conv = Conversation.last
        msg = Message.last

        expect(conv.organization).to eq(org)
        expect(conv.subject).to eq("Test inbound message")
        expect(conv.from_address).to eq("sender@example.com")
        expect(conv.status).to eq(Conversation::STATUS_OPEN)

        expect(msg.conversation).to eq(conv)
        expect(msg.organization).to eq(org)
        expect(msg.from_address).to eq("sender@example.com")
        expect(msg.to_address).to eq("support@acme.com")
        expect(msg.is_inbound).to be true
        expect(msg.body_plain).to eq("Hello, this is a test message.")
      end
    end

    context "threading via In-Reply-To (spec 3.1.3)" do
      it "adds message to existing conversation when In-Reply-To matches" do
        existing_conv = create(:conversation, organization: org, subject: "Original thread")
        existing_msg = create(:message,
          conversation: existing_conv,
          organization: org,
          message_id_header: "<original-123@example.com>",
          from_address: "support@acme.com"
        )

        payload = build_payload(
          "headers" => {
            "in_reply_to" => "<original-123@example.com>",
            "subject" => "Re: Original thread"
          }
        )

        expect { described_class.new(payload).process }
          .to change(Message, :count).by(1)
          .and change(Conversation, :count).by(0)

        new_msg = Message.last
        expect(new_msg.conversation).to eq(existing_conv)
      end

      [Conversation::STATUS_TRASH, Conversation::STATUS_ARCHIVED].each do |hidden|
        it "revives a #{hidden} thread back to the inbox (open + unread) on a new message" do
          existing_conv = create(:conversation,
            organization: org, subject: "Dormant thread", status: hidden, read: true)
          create(:message,
            conversation: existing_conv, organization: org,
            message_id_header: "<dormant-1@example.com>", from_address: "support@acme.com")

          payload = build_payload(
            "headers" => { "in_reply_to" => "<dormant-1@example.com>", "subject" => "Re: Dormant thread" }
          )
          described_class.new(payload).process

          existing_conv.reload
          expect(existing_conv.status).to eq(Conversation::STATUS_OPEN)
          expect(existing_conv.read).to be(false)
        end
      end

      it "leaves a spam thread in spam (not revived) on a new message" do
        existing_conv = create(:conversation,
          organization: org, subject: "Junk thread", status: Conversation::STATUS_SPAM, read: true)
        create(:message,
          conversation: existing_conv, organization: org,
          message_id_header: "<junk-1@example.com>", from_address: "spammer@acme.com")

        payload = build_payload(
          "headers" => { "in_reply_to" => "<junk-1@example.com>", "subject" => "Re: Junk thread" }
        )
        described_class.new(payload).process

        expect(existing_conv.reload.status).to eq(Conversation::STATUS_SPAM)
      end

      it "refreshes the conversation list-row preview (sender + snippet) to the newest message" do
        existing_conv = create(:conversation,
          organization: org,
          subject: "Original thread",
          from_address: "support@acme.com",
          snippet: "the original opening message"
        )
        create(:message,
          conversation: existing_conv,
          organization: org,
          message_id_header: "<original-123@example.com>",
          from_address: "support@acme.com"
        )

        payload = build_payload(
          "headers" => {
            "in_reply_to" => "<original-123@example.com>",
            "subject" => "Re: Original thread",
            "from" => "Alice Sender <sender@example.com>"
          },
          "body" => { "plain" => "This is the latest reply in the thread." }
        )

        described_class.new(payload).process

        existing_conv.reload
        # Sender + snippet must track the newest message, not stay frozen at the
        # thread-originator; subject stays the thread title.
        expect(existing_conv.from_address).to eq("sender@example.com")
        expect(existing_conv.snippet).to include("latest reply")
        expect(existing_conv.subject).to eq("Original thread")
      end
    end

    context "threading via References (spec 3.1.3)" do
      it "finds conversation via References header when In-Reply-To is empty" do
        existing_conv = create(:conversation, organization: org, subject: "Referenced thread")
        existing_msg = create(:message,
          conversation: existing_conv,
          organization: org,
          message_id_header: "<ref-ancestor-001@example.com>",
          from_address: "support@acme.com"
        )

        payload = build_payload(
          "headers" => {
            "in_reply_to" => "",
            "references" => "<ref-ancestor-001@example.com> <ref-parent-001@example.com>",
            "subject" => "Re: Referenced thread"
          }
        )

        expect { described_class.new(payload).process }
          .to change(Message, :count).by(1)
          .and change(Conversation, :count).by(0)

        new_msg = Message.last
        expect(new_msg.conversation).to eq(existing_conv)
      end
    end

    context "threading via subject fallback" do
      it "threads into existing conversation with matching subject within 30 days" do
        existing_conv = create(:conversation,
          organization: org,
          subject: "Billing inquiry",
          from_address: "Sender@example.com", to_address: "support@acme.com",
          created_at: 10.days.ago
        )

        payload = build_payload(
          "headers" => {
            "in_reply_to" => "",
            "references" => "",
            "subject" => "Re: Billing inquiry"
          }
        )

        expect { described_class.new(payload).process }
          .to change(Message, :count).by(1)
          .and change(Conversation, :count).by(0)

        expect(Message.last.conversation).to eq(existing_conv)
      end

      it "threads our own outbound thread when its recipient replies" do
        ours = create(:conversation, organization: org, subject: "Quote request",
                      from_address: "support@acme.com", to_address: "sender@example.com", created_at: 2.days.ago)
        described_class.new(build_payload("headers" => { "subject" => "Re: Quote request" })).process
        expect(Message.last.conversation).to eq(ours)
      end

      it "never merges the same subject sent to a different recipient (one invite per person)" do
        theirs = create(:conversation, organization: org, subject: "You're invited to Gluom",
                        from_address: "sender@example.com", to_address: "ceyhun@acme.com", created_at: 1.hour.ago)
        expect { described_class.new(build_payload("headers" => { "subject" => "You're invited to Gluom" })).process }
          .to change(Conversation, :count).by(1)
        expect(Message.last.conversation).not_to eq(theirs)
      end

      it "does not thread on short subjects" do
        create(:conversation, organization: org, subject: "Hi", created_at: 1.day.ago)

        payload = build_payload(
          "headers" => { "subject" => "Re: Hi" }
        )

        expect { described_class.new(payload).process }
          .to change(Conversation, :count).by(1)
      end

      it "does not thread on subjects older than 30 days" do
        create(:conversation, organization: org, subject: "Old thread topic", created_at: 60.days.ago)

        payload = build_payload(
          "headers" => { "subject" => "Re: Old thread topic" }
        )

        expect { described_class.new(payload).process }
          .to change(Conversation, :count).by(1)
      end
    end

    context "alias domains" do
      it "routes to organization via alias domain" do
        create(:domain, organization: org, name: "help.acme.com", status: "verified")

        payload = build_payload(
          "envelope" => { "rcpt_to" => ["support@help.acme.com"] }
        )

        result = described_class.new(payload).process
        expect(result[:conversation].organization).to eq(org)
      end
    end

    context "unknown domain" do
      it "returns nil for unknown domain" do
        payload = build_payload(
          "envelope" => { "rcpt_to" => ["user@unknown.com"] }
        )

        result = described_class.new(payload).process
        expect(result).to be_nil
      end
    end

    context "billing-locked domain" do
      it "returns nil (mail bounces) for a locked recipient domain" do
        org.default_domain.update!(locked_at: Time.current)
        payload = build_payload(
          "envelope" => { "rcpt_to" => ["user@acme.com"] }
        )

        result = described_class.new(payload).process
        expect(result).to be_nil
      end
    end

    context "attachments" do
      it "creates attachment metadata records (spec 4.1.4)" do
        payload = build_payload(
          "attachments" => [
            { "filename" => "report.pdf", "content_type" => "application/pdf", "size_bytes" => 45200, "is_inline" => false },
            { "filename" => "logo.png", "content_type" => "image/png", "size_bytes" => 8192, "is_inline" => true }
          ]
        )

        expect { described_class.new(payload).process }
          .to change(Attachment, :count).by(2)

        attachments = Attachment.last(2)
        expect(attachments.map(&:filename)).to contain_exactly("report.pdf", "logo.png")
        # storage_key may be nil (S3 unavailable) or populated (S3 available)
        # In test env without Garage, keys are nil; with Garage, they're S3 paths
      end
    end

    context "conversation snippet" do
      it "updates conversation snippet from message body" do
        payload = build_payload(
          "body" => { "plain" => "This is the message body for snippet extraction." }
        )

        described_class.new(payload).process
        conv = Conversation.last
        expect(conv.snippet).to include("snippet extraction")
      end
    end

    context "routing rules (spec 7.1.3)" do
      it "executes rules after creating the message" do
        tag = create(:tag, organization: org, name: "support")
        create(:rule, organization: org,
          conditions: [{ "field" => "from", "operator" => "contains", "value" => "sender@" }],
          actions: [{ "type" => "add_tag", "value" => "support" }])

        payload = build_payload

        described_class.new(payload).process
        conv = Conversation.last
        expect(conv.tags).to include(tag)
      end
    end

    context "DMARC quarantine (spec 11.1)" do
      it "sets conversation status to spam when DMARC quarantine" do
        payload = build_payload(
          "authentication" => {
            "dmarc" => { "result" => "fail", "policy" => "quarantine" }
          }
        )

        described_class.new(payload).process
        conv = Conversation.last
        expect(conv.status).to eq(Conversation::STATUS_SPAM)
      end
    end

    context "no subject" do
      it "uses (no subject) as fallback" do
        payload = build_payload(
          "headers" => { "subject" => "" }
        )

        described_class.new(payload).process
        expect(Conversation.last.subject).to eq("(no subject)")
      end
    end

    context "blocklist (spec 11.1.4)" do
      it "rejects messages from blocklisted senders" do
        MailFilter.create!(organization: org, kind: MailFilter::KIND_BLOCKLIST, value: "sender@example.com")
        payload = build_payload

        result = described_class.new(payload).process
        expect(result).to eq(:rejected)
        expect(Conversation.count).to eq(0)
      end

      it "rejects messages from blocklisted domains" do
        MailFilter.create!(organization: org, kind: MailFilter::KIND_BLOCKLIST, value: "example.com")
        payload = build_payload

        result = described_class.new(payload).process
        expect(result).to eq(:rejected)
      end
    end

    # The Facebook-security-code case: every one of those mails carries a fresh
    # subject, so it threads as a NEW conversation and marking the last one spam
    # can never file the next one. The junk filter is what makes it stick.
    context "junk senders" do
      it "files a new thread from a junked sender straight into spam" do
        MailFilter.create!(organization: org, kind: MailFilter::KIND_JUNK, value: "sender@example.com")

        described_class.new(build_payload).process

        expect(Conversation.last.status).to eq(Conversation::STATUS_SPAM)
      end

      it "files it as spam on a free plan too (no Rspamd involved)" do
        MailFilter.create!(organization: org, kind: MailFilter::KIND_JUNK, value: "example.com")
        expect_any_instance_of(RspamdClient).not_to receive(:check)

        described_class.new(build_payload).process

        expect(Conversation.last.status).to eq(Conversation::STATUS_SPAM)
      end

      it "delivers, never rejects — the mail stays recoverable in spam" do
        MailFilter.create!(organization: org, kind: MailFilter::KIND_JUNK, value: "sender@example.com")

        expect { described_class.new(build_payload).process }.to change(Message, :count).by(1)
      end

      it "lets an allowlist entry win over a junked domain" do
        MailFilter.create!(organization: org, kind: MailFilter::KIND_JUNK, value: "example.com")
        MailFilter.create!(organization: org, kind: MailFilter::KIND_ALLOWLIST, value: "sender@example.com")

        described_class.new(build_payload).process

        expect(Conversation.last.status).to eq(Conversation::STATUS_OPEN)
      end
    end

    context "allowlist (spec 11.1.5)" do
      it "processes allowlisted senders without spam scoring" do
        MailFilter.create!(organization: org, kind: MailFilter::KIND_ALLOWLIST, value: "sender@example.com")
        payload = build_payload

        # Should succeed — no Rspamd call needed for allowlisted senders
        expect { described_class.new(payload).process }
          .to change(Conversation, :count).by(1)
      end
    end

    context "spam scoring (spec 11.1.2)" do
      it "stores spam score on message when Rspamd returns a result" do
        # Mock RspamdClient to return a spam score
        spam_result = RspamdClient::CheckResult.new(score: 3.2, action: "no action", symbols: [{ "name" => "DKIM_SIGNED", "score" => -0.1 }], required_score: 7.0)
        allow_any_instance_of(RspamdClient).to receive(:check).and_return(spam_result)

        # Need a paid plan for spam scoring
        org.create_subscription!(plan: Plan.max, status: Subscription::STATUS_ACTIVE)

        payload = build_payload("raw_message_b64" => Base64.strict_encode64("From: test@example.com\r\n\r\nBody"))

        described_class.new(payload).process
        msg = Message.last
        expect(msg.spam_score).to eq(3.2)
        expect(msg.spam_action).to eq("no action")
      end

      it "marks conversation as spam when score exceeds threshold" do
        spam_result = RspamdClient::CheckResult.new(score: 12.5, action: "reject", symbols: [], required_score: 7.0)
        allow_any_instance_of(RspamdClient).to receive(:check).and_return(spam_result)

        org.create_subscription!(plan: Plan.max, status: Subscription::STATUS_ACTIVE)

        payload = build_payload("raw_message_b64" => Base64.strict_encode64("From: spam@bad.com\r\n\r\nBuy now!"))

        described_class.new(payload).process
        conv = Conversation.last
        expect(conv.status).to eq(Conversation::STATUS_SPAM)
      end

      it "skips spam scoring for free plan" do
        # No subscription = free plan, spam_filter = false
        expect_any_instance_of(RspamdClient).not_to receive(:check)

        payload = build_payload("raw_message_b64" => Base64.strict_encode64("From: test@example.com\r\n\r\nBody"))
        described_class.new(payload).process
        expect(Message.last.spam_score).to be_nil
      end
    end

    context "AI triage / Space classification (paid-plan gate)" do
      before { allow(SpaceClassifier).to receive(:enabled?).and_return(true) }

      it "enqueues classification for a new thread on a paid plan" do
        org.create_subscription!(plan: Plan.paid, status: Subscription::STATUS_ACTIVE)

        expect(ClassifySpaceJob).to receive(:perform_later).with(kind_of(Integer), true)
        described_class.new(build_payload).process
      end

      it "skips classification on a free plan (no Jev calls)" do
        # No subscription = free plan, ai_triage = false.
        expect(ClassifySpaceJob).not_to receive(:perform_later)
        described_class.new(build_payload).process
      end

      it "DEFERS a new thread's mobile push to the triage job" do
        org.create_subscription!(plan: Plan.paid, status: Subscription::STATUS_ACTIVE)
        allow(ClassifySpaceJob).to receive(:perform_later)

        # No inline alert: the deferred ClassifySpaceJob owns it.
        expect(MobilePushSender).not_to receive(:notify_new_message)
        described_class.new(build_payload).process
      end

      it "re-triages a reply on an existing thread and pushes it inline" do
        org.create_subscription!(plan: Plan.paid, status: Subscription::STATUS_ACTIVE)
        allow(ClassifySpaceJob).to receive(:perform_later)
        described_class.new(build_payload("headers" => { "message_id" => "<first-1@example.com>" })).process
        conv = Conversation.last

        expect(ClassifySpaceJob).to receive(:perform_later).with(conv.id, false)
        expect(MobilePushSender).to receive(:notify_new_message)
        described_class.new(build_payload("headers" => { "in_reply_to" => "<first-1@example.com>",
                                                         "subject" => "Re: Test inbound message" })).process
      end
    end

    context "mobile push (docs/Cloud-Push.md)" do
      it "sends a visible push to every active human member" do
        second = create(:user, username: "second_member")
        create(:membership, user: second, organization: org,
          role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)

        notified = []
        allow(MobilePushSender).to receive(:new_message) { |user, **| notified << user }

        described_class.new(build_payload).process

        expect(notified).to match_array([ owner, second ])
      end

      it "skips inactive memberships and agents" do
        invited = create(:user, username: "invited_member")
        create(:membership, user: invited, organization: org,
          role: Membership::ROLE_MEMBER, status: Membership::STATUS_INVITED)
        create(:membership, organization: org, member_type: Membership::TYPE_AGENT,
          role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)

        notified = []
        allow(MobilePushSender).to receive(:new_message) { |user, **| notified << user }

        described_class.new(build_payload).process

        expect(notified).to eq([ owner ])
      end

      it "never alerts for a spam conversation" do
        expect(MobilePushSender).not_to receive(:new_message)

        conversation = create(:conversation, organization: org, status: Conversation::STATUS_SPAM)
        message = create(:message, conversation: conversation, organization: org)
        described_class.new(build_payload).send(:notify_mobile_devices, org, conversation, message)
      end

      it "does not let a push failure break mail processing" do
        allow(MobilePushSender).to receive(:new_message).and_raise("fcm down")

        expect { described_class.new(build_payload).process }
          .to change(Message, :count).by(1)
      end
    end

    context "retired mailbox aliases" do
      it "drops mail to a bounced local_part without threading" do
        org.mailbox_aliases.create!(domain: org.default_domain, local_part: "support", mode: MailboxAlias::MODE_BOUNCE)
        payload = build_payload("envelope" => { "rcpt_to" => ["support@acme.com"] })

        expect { described_class.new(payload).process }.not_to change(Message, :count)
        expect(Conversation.count).to eq(0)
      end

      it "accepts rerouted mail and grants the target member conversation access" do
        target = create(:user, username: "rerouted_to")
        target_m = create(:membership, user: target, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
        org.mailbox_aliases.create!(domain: org.default_domain, local_part: "support", mode: MailboxAlias::MODE_REROUTE, target_membership: target_m)
        payload = build_payload("envelope" => { "rcpt_to" => ["support@acme.com"] })

        expect { described_class.new(payload).process }.to change(Message, :count).by(1)
        # accessible_members is sourced from conversation_accesses → memberships.
        expect(Conversation.last.accessible_members).to include(target_m)
      end

      it "bounces a reroute whose target was removed (nil target)" do
        org.mailbox_aliases.create!(domain: org.default_domain, local_part: "support", mode: MailboxAlias::MODE_BOUNCE, target_membership: nil)
        payload = build_payload("envelope" => { "rcpt_to" => ["support@acme.com"] })

        expect { described_class.new(payload).process }.not_to change(Message, :count)
      end
    end
  end

  # Out-of-office auto-reply (docs/Calendar.md) — the end-to-end hook. The unit
  # rules live in out_of_office_responder_spec; this proves the pipeline calls it
  # with the raw source the loop guards need.
  describe "out-of-office auto-reply" do
    let!(:mailbox) { Mailbox.create!(membership: membership, domain: org.domains.first, local_part: "support") }

    before do
      owner.update!(out_of_office_start: 1.day.ago, out_of_office_end: 5.days.from_now,
                    out_of_office_message: "Away until Monday.")
    end

    def raw_source(headers = {})
      base = { "From" => "sender@example.com", "To" => "support@acme.com", "Subject" => "Test" }.merge(headers)
      Base64.strict_encode64(base.map { |k, v| "#{k}: #{v}" }.join("\r\n") + "\r\n\r\nHello\r\n")
    end

    it "replies to a human sender addressed to the away mailbox" do
      described_class.new(build_payload("raw_message_b64" => raw_source)).process

      reply = org.messages.where(is_inbound: false).order(:id).last
      expect(reply).to be_present
      expect(reply.to_address).to eq("sender@example.com")
      expect(reply.body_plain).to eq("Away until Monday.")
      expect(reply.auto_submitted).to eq(Message::AUTO_SUBMITTED_REPLIED)
    end

    it "records the reply so a second mail from the same sender is not answered" do
      described_class.new(build_payload("raw_message_b64" => raw_source)).process
      expect {
        described_class.new(build_payload("raw_message_b64" => raw_source)).process
      }.not_to change { org.messages.where(is_inbound: false).count }
    end

    it "does not answer an automatic message (negative)" do
      described_class.new(
        build_payload("raw_message_b64" => raw_source("Auto-Submitted" => "auto-generated"))
      ).process

      expect(org.messages.where(is_inbound: false).count).to eq(0)
    end

    it "does not answer when nobody is away (negative)" do
      owner.update!(out_of_office_start: nil, out_of_office_end: nil)
      described_class.new(build_payload("raw_message_b64" => raw_source)).process

      expect(org.messages.where(is_inbound: false).count).to eq(0)
    end

    it "stores the inbound mail even when the auto-reply blows up" do
      allow(OutOfOfficeResponder).to receive(:maybe_reply).and_raise("boom")

      result = described_class.new(build_payload("raw_message_b64" => raw_source)).process
      expect(result[:message]).to be_present
    end
  end
end
