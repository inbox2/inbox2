require "rails_helper"

RSpec.describe "Api::V1::Messages", type: :request do
  let(:owner) { create(:user, username: "msgowner") }
  let(:org) { create(:organization, owner: owner, domain: "msg.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:sender_box) { create(:mailbox, membership: owner_membership, domain: org.default_domain, local_part: "user") }
  let(:headers) { auth_headers(owner) }

  # --- Spec 4.2.1, 8.1.2, A7.1 — Send message ---
  describe "POST /api/v1/orgs/:org_id/messages" do
    context "positive — reply to existing conversation" do
      let!(:conv) { create(:conversation, organization: org, subject: "Test thread") }

      it "adds a message to an existing conversation" do
        expect {
          post "/api/v1/orgs/#{org.key}/messages",
               params: {
                 conversation_id: conv.key,
                 from_address: "user@msg.com",
                 to_address: "customer@example.com",
                 body_plain: "Thanks for reaching out!"
               },
               headers: headers
        }.to change(Message, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["message"]["id"]).to start_with("msg_")
        expect(body["message"]["from_address"]).to eq("user@msg.com")
        expect(body["message"]["is_inbound"]).to eq(false)
      end

      it "answers a retried send with the message it already made" do
        send = lambda do
          post "/api/v1/orgs/#{org.key}/messages",
               params: { conversation_id: conv.key, message_id_header: "<mxo_1@msg.com>", from_address: "user@msg.com",
                         to_address: "c@example.com", body_plain: "once" },
               headers: headers
        end
        expect { send.call }.to change(Message, :count).by(1)
        first = response.parsed_body["message"]["id"]
        expect { send.call }.to have_enqueued_job(OutboundDeliveryJob)
        expect(Message.where(message_id_header: "<mxo_1@msg.com>").count).to eq(1)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["message"]["id"]).to eq(first)
      end

      it "won't answer with someone else's message under a reused Message-ID" do
        create(:message, conversation: conv, organization: org, is_inbound: true, message_id_header: "<theirs@x.com>")
        post "/api/v1/orgs/#{org.key}/messages",
             params: { conversation_id: conv.key, message_id_header: "<theirs@x.com>", from_address: "user@msg.com",
                       to_address: "c@example.com", body_plain: "hi" },
             headers: headers
        expect(response).to have_http_status(:conflict)
      end

      it "threads the reply on the wire: In-Reply-To and References from the parent" do
        older = create(:message, conversation: conv, organization: org, message_id_header: "<a@x>", created_at: 2.days.ago)
        create(:message, conversation: conv, organization: org, message_id_header: "<b@x>",
                         references_header: "<a@x>", created_at: 1.day.ago)
        post "/api/v1/orgs/#{org.key}/messages",
             params: { conversation_id: conv.key, from_address: "user@msg.com", to_address: "c@example.com", body_plain: "Re" },
             headers: headers
        reply = Message.find_by!(key: response.parsed_body["message"]["id"])
        expect(reply.in_reply_to).to eq("<b@x>")
        expect(reply.references_header).to eq("<a@x> <b@x>")

        post "/api/v1/orgs/#{org.key}/messages",
             params: { conversation_id: conv.key, reply_to_message_id: older.key, from_address: "user@msg.com",
                       to_address: "c@example.com", body_plain: "Re" },
             headers: headers
        expect(Message.find_by!(key: response.parsed_body["message"]["id"]).in_reply_to).to eq("<a@x>")
      end

      # docs/Triage.md: the owner spoke last, so the thread waits on the other
      # side — a rule, no Jev call.
      it "labels the thread waiting_reply by rule" do
        conv.update!(triage_label: TriageLabel::NEEDS_ANSWER, triage_source: "jev:jev-1.13.0")
        post "/api/v1/orgs/#{org.key}/messages",
             params: { conversation_id: conv.key, from_address: "user@msg.com",
                       to_address: "customer@example.com", body_plain: "Here you go" },
             headers: headers
        expect(response).to have_http_status(:created)
        expect(conv.reload.triage_label).to eq(TriageLabel::WAITING_REPLY)
        expect(conv.triage_source).to eq(TriageLabel::SOURCE_RULE_SENT)
      end

      it "updates conversation snippet" do
        post "/api/v1/orgs/#{org.key}/messages",
             params: {
               conversation_id: conv.key,
               from_address: "user@msg.com",
               to_address: "customer@example.com",
               body_plain: "Updated snippet text here"
             },
             headers: headers
        expect(conv.reload.snippet).to eq("Updated snippet text here")
      end
    end

    context "positive — the sent copy lands in Sent" do
      it "shows up under the Sent view's direction=outbound filter, BCC and all" do
        post "/api/v1/orgs/#{org.key}/messages",
             params: {
               from_address: "user@msg.com",
               to_address: "customer@example.com",
               cc_address: "cc@example.com",
               bcc_address: "blind@example.com",
               subject: "Kept in Sent",
               body_plain: "Body"
             },
             headers: headers
        expect(response).to have_http_status(:created)
        msg_key = response.parsed_body["message"]["id"]

        get "/api/v1/orgs/#{org.key}/conversations", params: { direction: "outbound" }, headers: headers
        expect(response).to have_http_status(:ok)
        convs = response.parsed_body["conversations"]
        expect(convs.map { |c| c["subject"] }).to include("Kept in Sent")

        get "/api/v1/orgs/#{org.key}/conversations/#{convs.first['id']}", headers: headers
        sent = response.parsed_body["conversation"]["messages"].find { |m| m["id"] == msg_key }
        expect(sent).to be_present
        expect(sent["is_draft"]).to eq(false)
        expect(sent["cc_address"]).to eq("cc@example.com")
        expect(sent["bcc_address"]).to eq("blind@example.com")
      end
    end

    context "positive — outbound delivery (spec 20.2.1)" do
      let!(:conv) { create(:conversation, organization: org, subject: "Deliver me") }

      it "enqueues OutboundDeliveryJob for the created message" do
        expect {
          post "/api/v1/orgs/#{org.key}/messages",
               params: {
                 conversation_id: conv.key,
                 from_address: "user@msg.com",
                 to_address: "customer@example.com",
                 body_plain: "Ship it"
               },
               headers: headers
        }.to have_enqueued_job(OutboundDeliveryJob)
        expect(response).to have_http_status(:created)
      end
    end

    context "negative — validation failure does not enqueue delivery" do
      it "does not enqueue OutboundDeliveryJob when the message is invalid" do
        expect {
          post "/api/v1/orgs/#{org.key}/messages",
               params: { to_address: "someone@example.com", body_plain: "No sender" },
               headers: headers
        }.not_to have_enqueued_job(OutboundDeliveryJob)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "positive — new conversation" do
      it "creates a new conversation and message" do
        expect {
          post "/api/v1/orgs/#{org.key}/messages",
               params: {
                 from_address: "user@msg.com",
                 to_address: "newcustomer@example.com",
                 subject: "Welcome!",
                 body_plain: "Welcome to our service."
               },
               headers: headers
        }.to change(Conversation, :count).by(1).and change(Message, :count).by(1)

        expect(response).to have_http_status(:created)
      end

      it "files the new thread under the sender's domain, so Sent shows it" do
        domain = create(:domain, organization: org, name: "sent.com")
        create(:mailbox, membership: owner_membership, domain: domain, local_part: "me")
        post "/api/v1/orgs/#{org.key}/messages",
             params: { from_address: "Me <me@Sent.com>", to_address: "x@example.com", subject: "Hi", body_plain: "hi" },
             headers: headers
        expect(Conversation.last.domain_id).to eq(domain.id)
      end
    end

    context "negative — sending as someone else" do
      let(:other) { create(:membership, organization: org, role: "member", status: "active") }

      it "refuses a colleague's address on the same domain" do
        create(:mailbox, membership: other, domain: org.default_domain, local_part: "colleague")
        post "/api/v1/orgs/#{org.key}/messages",
             params: { from_address: "colleague@msg.com", to_address: "x@example.com", subject: "Hi", body_plain: "hi" },
             headers: headers
        expect(response).to have_http_status(:forbidden)
      end

      it "refuses a domain the member is not scoped to, even under their own name" do
        scoped_user = create(:user)
        scoped = create(:membership, user: scoped_user, organization: org, role: "member", status: "active", all_domains: false)
        create(:domain, organization: org, name: "other.com")
        post "/api/v1/orgs/#{org.key}/messages",
             params: { from_address: "#{scoped_user.username}@other.com", to_address: "x@example.com", body_plain: "hi" },
             headers: auth_headers(scoped_user)
        expect(response).to have_http_status(:forbidden)
        expect(scoped.reload.id).to be_present
      end

      it "allows the member's username on a domain they can see" do
        post "/api/v1/orgs/#{org.key}/messages",
             params: { from_address: "#{owner.username}@msg.com", to_address: "x@example.com", subject: "Hi", body_plain: "hi" },
             headers: headers
        expect(response).to have_http_status(:created)
      end
    end

    context "negative — attachments over the size cap" do
      it "refuses a send whose attachments add up to more than 25 MB" do
        draft = create(:message, organization: org, conversation: create(:conversation, organization: org), is_draft: true)
        keys = 2.times.map { create(:attachment, message: draft, size_bytes: 13 * 1024 * 1024).key }
        post "/api/v1/orgs/#{org.key}/messages",
             params: { from_address: "user@msg.com", to_address: "x@example.com", body_plain: "hi", attachment_keys: keys },
             headers: headers
        expect(response).to have_http_status(:content_too_large)
      end
    end

    context "negative — missing from_address" do
      it "rejects message without from_address" do
        post "/api/v1/orgs/#{org.key}/messages",
             params: {
               to_address: "someone@example.com",
               body_plain: "No sender"
             },
             headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a conversation in another org" do
        other_user = create(:user, username: "msgiso")
        other_org = create(:organization, owner: other_user, domain: "msgiso.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        other_conv = create(:conversation, organization: other_org)

        post "/api/v1/orgs/#{org.key}/messages",
             params: {
               conversation_id: other_conv.key,
               from_address: "user@msg.com",
               to_address: "someone@example.com",
               body_plain: "Cross-tenant"
             },
             headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — unauthorized" do
      it "rejects unauthenticated request" do
        post "/api/v1/orgs/#{org.key}/messages",
             params: { from_address: "user@msg.com", body_plain: "test" }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # --- messages#schedule — schedule a draft for future send ---
  describe "POST /api/v1/orgs/:org_id/messages/:id/schedule" do
    let!(:conv) { create(:conversation, organization: org) }
    let!(:draft) { create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: owner_membership.id) }

    context "positive" do
      it "returns the scheduled time for a draft" do
        post "/api/v1/orgs/#{org.key}/messages/#{draft.key}/schedule",
             params: { send_at: 1.hour.from_now.iso8601 }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["scheduled_at"]).to be_present
      end

      it "promotes the draft and enqueues deferred delivery at send_at" do
        send_at = 1.hour.from_now.change(usec: 0)
        expect {
          post "/api/v1/orgs/#{org.key}/messages/#{draft.key}/schedule",
               params: { send_at: send_at.iso8601 }, headers: headers
        }.to have_enqueued_job(OutboundDeliveryJob).with(draft.id).at(send_at)
        expect(draft.reload.is_draft).to be false
        expect(draft.scheduled_at).to be_within(1.second).of(send_at)
      end
    end

    context "negative" do
      it "returns 404 for a non-draft message" do
        sent = create(:message, conversation: conv, organization: org, is_draft: false)
        post "/api/v1/orgs/#{org.key}/messages/#{sent.key}/schedule",
             params: { send_at: 1.hour.from_now.iso8601 }, headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "returns 422 when send_at is in the past" do
        post "/api/v1/orgs/#{org.key}/messages/#{draft.key}/schedule",
             params: { send_at: 1.hour.ago.iso8601 }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(draft.reload.is_draft).to be true
      end

      it "returns 422 for an unparseable send_at" do
        post "/api/v1/orgs/#{org.key}/messages/#{draft.key}/schedule",
             params: { send_at: "not-a-date" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "a new thread from a personal address" do
    it "is stamped with its member, so it stays theirs even without stored addresses" do
      post "/api/v1/orgs/#{org.key}/messages",
           params: { from_address: "user@msg.com", to_address: "x@example.com", subject: "Mine", body_plain: "hi" }, headers: headers
      conv = Conversation.find_by!(key: response.parsed_body.dig("message", "conversation_id"))
      expect(conv.personal_membership_id).to eq(owner_membership.id)
    end

    it "from a shared address, takes the first To recipient's member (formatted, several recipients)" do
      owner_membership.update!(send_as_addresses: ["info@msg.com"])
      mate = create(:membership, organization: org, role: "member", status: "active")
      create(:mailbox, membership: mate, domain: org.default_domain, local_part: "mate")
      post "/api/v1/orgs/#{org.key}/messages",
           params: { from_address: "info@msg.com", to_address: "Mate <MATE@msg.com>, ext@example.com", subject: "Hi", body_plain: "hi" },
           headers: headers
      conv = Conversation.find_by!(key: response.parsed_body.dig("message", "conversation_id"))
      expect(conv.personal_membership_id).to eq(mate.id)
      expect(org.conversations.org_readable).not_to include(conv)
      # The sender keeps what they sent (and can undo it); other teammates don't see it.
      expect(org.conversations.visible_to(owner_membership)).to include(conv)
      third = create(:membership, organization: org, role: "admin", status: "active")
      expect(org.conversations.visible_to(third)).not_to include(conv)

      post "/api/v1/orgs/#{org.key}/messages/#{response.parsed_body.dig("message", "id")}/cancel-send", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "resolves a formatted From (Name <addr>) to its member" do
      expect(org.personal_membership_id_for("User Name <USER@msg.com>")).to eq(owner_membership.id)
      expect(org.personal_membership_id_for("Shared <info@msg.com>")).to be_nil
    end
  end

  # --- messages#cancel_send — undo-send within a short window ---
  describe "POST /api/v1/orgs/:org_id/messages/:id/cancel-send" do
    let!(:conv) { create(:conversation, organization: org) }

    context "positive" do
      it "cancels a just-sent message within the window" do
        message = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: false, from_address: "user@msg.com", sender_membership_id: owner_membership.id)
        post "/api/v1/orgs/#{org.key}/messages/#{message.key}/cancel-send", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["cancelled"]).to be true
        expect(message.reload.is_draft).to be true
      end

      it "the deferred delivery job then skips the cancelled (draft) message" do
        message = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: false, from_address: "user@msg.com", sender_membership_id: owner_membership.id)
        post "/api/v1/orgs/#{org.key}/messages/#{message.key}/cancel-send", headers: headers
        expect(message.reload.is_draft).to be true
        # The delivery job no-ops on a draft, so nothing is published.
        expect(OutboundMailPublisher).not_to receive(:new)
        OutboundDeliveryJob.perform_now(message.id)
      end

      it "cancels a future scheduled send even outside the undo window" do
        message = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: false, from_address: "user@msg.com", sender_membership_id: owner_membership.id,
                         created_at: 1.hour.ago, scheduled_at: 2.hours.from_now)
        post "/api/v1/orgs/#{org.key}/messages/#{message.key}/cancel-send", headers: headers
        expect(response).to have_http_status(:ok)
        expect(message.reload.is_draft).to be true
        expect(message.scheduled_at).to be_nil
      end
    end

    context "negative" do
      it "returns 422 after the cancellation window has passed" do
        message = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: false, from_address: "user@msg.com", sender_membership_id: owner_membership.id, created_at: 1.minute.ago)
        post "/api/v1/orgs/#{org.key}/messages/#{message.key}/cancel-send", headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "won't cancel an inbound message (which would re-privatize a shared thread)" do
        inbound = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: true)
        post "/api/v1/orgs/#{org.key}/messages/#{inbound.key}/cancel-send", headers: headers
        expect(response).to have_http_status(:not_found)
        expect(inbound.reload.is_draft).to be false
      end

      it "won't let a teammate take back a send from someone else's personal mailbox" do
        mate = create(:membership, organization: org, role: "member", status: "active")
        create(:mailbox, membership: mate, domain: org.default_domain, local_part: "mate")
        theirs = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: false, from_address: "mate@msg.com")
        post "/api/v1/orgs/#{org.key}/messages/#{theirs.key}/cancel-send", headers: headers
        expect(response).to have_http_status(:forbidden)
        expect(theirs.reload.is_draft).to be false
      end

      it "won't let a teammate undo a sealed send (no plaintext From to authorize against)" do
        mate = create(:membership, organization: org, role: "member", status: "active")
        sealed = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: false,
                        encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1, from_address: nil,
                        sender_membership_id: mate.id)
        post "/api/v1/orgs/#{org.key}/messages/#{sealed.key}/cancel-send", headers: headers
        expect(response).to have_http_status(:forbidden)
        expect(sealed.reload.is_draft).to be false
      end

      it "lets the recorded sender undo their own sealed send" do
        sealed = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: false,
                        encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1, from_address: nil,
                        sender_membership_id: owner_membership.id)
        post "/api/v1/orgs/#{org.key}/messages/#{sealed.key}/cancel-send", headers: headers
        expect(response).to have_http_status(:ok)
      end

      it "returns 404 for an unknown message" do
        post "/api/v1/orgs/#{org.key}/messages/msg_missing/cancel-send", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Meeting-invite RSVP (docs/Meeting-Invites.md) ---
  describe "POST /api/v1/orgs/:org_id/messages/:id/rsvp" do
    let!(:conv) { create(:conversation, organization: org, subject: "Sprint planning") }
    let!(:invite_msg) do
      create(:message, organization: org, conversation: conv, is_inbound: true,
             to_address: "user@msg.com", message_id_header: "<invite-1@ex.com>",
             rsvp_status: "needs_action",
             calendar_invite: {
               "method" => "REQUEST", "uid" => "evt-1@ex.com", "summary" => "Sprint planning",
               "organizer_email" => "alice@ex.com", "sequence" => 2
             })
    end

    context "positive" do
      it "records the response and emails a REPLY to the organizer" do
        expect {
          post "/api/v1/orgs/#{org.key}/messages/#{invite_msg.key}/rsvp",
               params: { status: "accepted" }, headers: headers
        }.to change(Message, :count).by(1) # the outbound REPLY

        expect(response).to have_http_status(:ok)
        expect(invite_msg.reload.rsvp_status).to eq("accepted")

        reply = conv.messages.order(:created_at).last
        expect(reply.to_address).to eq("alice@ex.com")
        expect(reply.in_reply_to).to eq("<invite-1@ex.com>")
        expect(reply.calendar_reply).to include("METHOD:REPLY")
        expect(reply.calendar_reply).to include("PARTSTAT=ACCEPTED")
        expect(reply.calendar_reply).to include("UID:evt-1@ex.com")
      end

      # docs/Calendar.md — answering the organizer and having the meeting show
      # up in your own week are two different things.
      context "placing the accepted invite on the member's calendar" do
        let!(:dated_invite) do
          create(:message, organization: org, conversation: conv, is_inbound: true,
                 to_address: "user@msg.com", message_id_header: "<invite-2@ex.com>",
                 rsvp_status: "needs_action",
                 calendar_invite: {
                   "method" => "REQUEST", "uid" => "evt-2@ex.com", "summary" => "Design sync",
                   "location" => "Room 1", "organizer_email" => "alice@ex.com",
                   "start" => "2026-03-02T10:00:00Z", "end" => "2026-03-02T11:00:00Z",
                   "sequence" => 0
                 })
        end

        it "creates the event on accept" do
          expect {
            post "/api/v1/orgs/#{org.key}/messages/#{dated_invite.key}/rsvp",
                 params: { status: "accepted" }, headers: headers
          }.to change { org.calendar_events.count }.by(1)

          event = org.calendar_events.last
          expect(event.title).to eq("Design sync")
          expect(event.ical_uid).to eq("evt-2@ex.com")
          expect(event.start_at).to eq(Time.utc(2026, 3, 2, 10))
          expect(event.status).to eq(CalendarEvent::STATUS_CONFIRMED)
        end

        it "removes the event again when the member declines" do
          post "/api/v1/orgs/#{org.key}/messages/#{dated_invite.key}/rsvp",
               params: { status: "accepted" }, headers: headers

          expect {
            post "/api/v1/orgs/#{org.key}/messages/#{dated_invite.key}/rsvp",
                 params: { status: "declined" }, headers: headers
          }.to change { org.calendar_events.count }.by(-1)
        end

        it "does not duplicate the event when the same invite is answered twice" do
          2.times do
            post "/api/v1/orgs/#{org.key}/messages/#{dated_invite.key}/rsvp",
                 params: { status: "accepted" }, headers: headers
          end

          expect(org.calendar_events.where(ical_uid: "evt-2@ex.com").count).to eq(1)
        end

        it "leaves the calendar alone for an invite carrying no start time" do
          expect {
            post "/api/v1/orgs/#{org.key}/messages/#{invite_msg.key}/rsvp",
                 params: { status: "accepted" }, headers: headers
          }.not_to change { org.calendar_events.count }
        end
      end
    end

    context "negative" do
      it "rejects an invalid status" do
        post "/api/v1/orgs/#{org.key}/messages/#{invite_msg.key}/rsvp",
             params: { status: "maybe" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "422s when the message is not an invite" do
        plain = create(:message, organization: org, conversation: conv)
        post "/api/v1/orgs/#{org.key}/messages/#{plain.key}/rsvp",
             params: { status: "accepted" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "404s for an unknown message" do
        post "/api/v1/orgs/#{org.key}/messages/msg_missing/rsvp",
             params: { status: "accepted" }, headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Add an emailed event to the calendar (docs/Meeting-Invites.md) ---
  # A PUBLISH .ics is a confirmation, not an invitation: there is nothing to answer,
  # so the action is filing it rather than RSVPing.
  describe "POST /api/v1/orgs/:org_id/messages/:id/calendar-import" do
    let!(:conv) { create(:conversation, organization: org, subject: "Your appointment") }
    let!(:published) do
      create(:message, organization: org, conversation: conv, is_inbound: true,
             to_address: "user@msg.com",
             calendar_invite: {
               "method" => "PUBLISH", "uid" => "BG438296294", "summary" => "Haircut",
               "location" => "Rotterdam", "start" => "2026-09-16T08:00:00Z",
               "end" => "2026-09-16T09:00:00Z", "sequence" => 0
             })
    end

    context "positive" do
      it "puts the event on the member's calendar" do
        expect {
          post "/api/v1/orgs/#{org.key}/messages/#{published.key}/calendar-import", headers: headers
        }.to change { org.calendar_events.count }.by(1)

        expect(response).to have_http_status(:ok)
        event = org.calendar_events.last
        expect(event.title).to eq("Haircut")
        expect(event.ical_uid).to eq("BG438296294")
        expect(event.start_at).to eq(Time.utc(2026, 9, 16, 8))
      end

      it "does not email anybody — nobody asked for an answer" do
        expect {
          post "/api/v1/orgs/#{org.key}/messages/#{published.key}/calendar-import", headers: headers
        }.not_to change(Message, :count)
      end

      it "does not duplicate the event when imported twice" do
        2.times { post "/api/v1/orgs/#{org.key}/messages/#{published.key}/calendar-import", headers: headers }
        expect(org.calendar_events.where(ical_uid: "BG438296294").count).to eq(1)
      end
    end

    context "detected meeting (no ICS)" do
      let!(:detected) do
        create(:message, organization: org, conversation: conv, is_inbound: true, to_address: "user@msg.com",
               detected_meeting: { "title" => "Viewing", "start" => "2026-10-07T16:30:00", "end" => nil,
                                   "location" => "Rotterdam" })
      end

      it "is served as a detected PUBLISH invite" do
        invite = MessageSerializer.new(detected).to_h["invite"]
        expect(invite).to include("method" => "PUBLISH", "detected" => true, "start" => "2026-10-07T16:30:00")
      end

      it "files it at the sender's wall clock in the viewer's zone" do
        post "/api/v1/orgs/#{org.key}/messages/#{detected.key}/calendar-import",
             params: { time_zone: "Europe/Amsterdam" }, headers: headers
        expect(response).to have_http_status(:ok), response.body
        event = org.calendar_events.find_by!(ical_uid: "detected-#{detected.key}@inbox2")
        expect(event.title).to eq("Viewing")
        expect(event.start_at).to eq(Time.utc(2026, 10, 7, 14, 30))
      end
    end

    context "negative" do
      it "422s when the message carries no event" do
        plain = create(:message, organization: org, conversation: conv)
        post "/api/v1/orgs/#{org.key}/messages/#{plain.key}/calendar-import", headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "422s when the event has no start time to place" do
        undated = create(:message, organization: org, conversation: conv, is_inbound: true,
                         calendar_invite: { "method" => "PUBLISH", "uid" => "no-start", "summary" => "?" })
        post "/api/v1/orgs/#{org.key}/messages/#{undated.key}/calendar-import", headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "404s for an unknown message" do
        post "/api/v1/orgs/#{org.key}/messages/msg_missing/calendar-import", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
