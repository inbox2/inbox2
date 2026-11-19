require "rails_helper"

RSpec.describe "Api::V1::Conversations", type: :request do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, username: "convowner") }
  let(:org) { create(:organization, owner: owner, domain: "conv.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # --- Attachments on messages (A7.2) ---
  #
  # Inbound MX mail has always created Attachment rows with an S3 storage_key,
  # and AttachmentsController has always been able to hand back a presigned URL —
  # but nothing put them in a message payload, so every attachment on every MX
  # message was invisible in every client. These pin the payload the clients now
  # read.
  describe "attachments on a conversation's messages" do
    let(:conversation) { create(:conversation, organization: org, subject: "With files") }
    let(:message) { create(:message, conversation: conversation, organization: org) }

    context "positive" do
      it "serializes each attachment with a download URL when the bytes exist" do
        create(:attachment, message: message, organization: org,
                            filename: "quote.pdf", content_type: "application/pdf",
                            size_bytes: 8_192, storage_key: "orgs/x/quote.pdf")

        get "/api/v1/orgs/#{org.key}/conversations/#{conversation.key}", headers: headers
        expect(response).to have_http_status(:ok)
        att = response.parsed_body.dig("conversation", "messages", 0, "attachments", 0)
        expect(att["filename"]).to eq("quote.pdf")
        expect(att["content_type"]).to eq("application/pdf")
        expect(att["size_bytes"]).to eq(8_192)
        expect(att["has_content"]).to be(true)
        expect(att["download_url"]).to eq("/api/v1/orgs/#{org.key}/attachments/#{att['id']}")
        # E5: public IDs only
        expect(att["id"]).to start_with("att_")
      end

      it "is an empty array on a message with no attachments" do
        message
        get "/api/v1/orgs/#{org.key}/conversations/#{conversation.key}", headers: headers
        expect(response.parsed_body.dig("conversation", "messages", 0, "attachments")).to eq([])
      end

      # A row can exist before its bytes land (the MX spools sealed ciphertext to
      # Garage after the row). The client must not offer a download that 404s.
      it "reports has_content false and no download URL before the bytes land" do
        create(:attachment, message: message, organization: org, storage_key: nil)

        get "/api/v1/orgs/#{org.key}/conversations/#{conversation.key}", headers: headers
        att = response.parsed_body.dig("conversation", "messages", 0, "attachments", 0)
        expect(att["has_content"]).to be(false)
        expect(att["download_url"]).to be_nil
      end

      it "flags the thread on the list endpoint so the row can show a paperclip" do
        create(:attachment, message: message, organization: org, storage_key: "k")
        plain = create(:conversation, organization: org, subject: "No files")
        create(:message, conversation: plain, organization: org)

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        by_subject = response.parsed_body["conversations"].index_by { |c| c["subject"] }
        expect(by_subject["With files"]["has_attachment"]).to be(true)
        expect(by_subject["No files"]["has_attachment"]).to be(false)
      end

      # The flag has to survive a caller that doesn't know to preload the page-wide
      # set — PATCH re-renders one conversation with no serializer params.
      it "still reports the flag when re-rendering a single conversation" do
        create(:attachment, message: message, organization: org, storage_key: "k")

        patch "/api/v1/orgs/#{org.key}/conversations/#{conversation.key}",
              params: { read: true }.to_json, headers: headers
        expect(response.parsed_body.dig("conversation", "has_attachment")).to be(true)
      end

      # One query for the whole page, not one per row: the list is the
      # highest-traffic endpoint in the app.
      it "does not issue a per-conversation query for the flag" do
        3.times do |i|
          conv = create(:conversation, organization: org, subject: "T#{i}")
          create(:attachment, message: create(:message, conversation: conv, organization: org),
                              organization: org, storage_key: "k")
        end

        queries = 0
        counter = ->(_n, _s, _f, _i, payload) do
          queries += 1 if payload[:sql]&.include?("attachments")
        end
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        end
        expect(queries).to eq(1)
      end
    end

    context "negative" do
      it "does not leak another org's attachment through a shared filename" do
        other_org = create(:organization, owner: create(:user, username: "otherowner"), domain: "other.com")
        other_msg = create(:message,
                           conversation: create(:conversation, organization: other_org),
                           organization: other_org)
        create(:attachment, message: other_msg, organization: other_org, filename: "secret.pdf")
        create(:attachment, message: message, organization: org, filename: "mine.pdf")

        get "/api/v1/orgs/#{org.key}/conversations/#{conversation.key}", headers: headers
        names = response.parsed_body.dig("conversation", "messages", 0, "attachments").map { |a| a["filename"] }
        expect(names).to eq(["mine.pdf"])
      end
    end
  end

  # --- Spec 3.1.1, 3.4.1, A6.1 — List conversations ---
  describe "GET /api/v1/orgs/:org_id/conversations" do
    context "positive" do
      it "lists conversations in the organization" do
        create(:conversation, organization: org, subject: "First thread")
        create(:conversation, organization: org, subject: "Second thread")

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["conversations"].length).to eq(2)
        # E5: public IDs only
        body["conversations"].each do |c|
          expect(c["id"]).to start_with("conv_")
          expect(c).not_to have_key("organization_id")
        end
      end

      # The generated one-line preview the clients show instead of the raw body
      # snippet. Null (not absent) before the classifier has run, so every client
      # can fall back to `snippet` without a shape check.
      it "exposes the generated one-line summary, and null when there isn't one" do
        create(:conversation, organization: org, subject: "Summarized", ai_summary_short: "Wants a refund")
        create(:conversation, organization: org, subject: "Untriaged")

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        by_subject = response.parsed_body["conversations"].index_by { |c| c["subject"] }
        expect(by_subject["Summarized"]["ai_summary_short"]).to eq("Wants a refund")
        expect(by_subject["Untriaged"]).to have_key("ai_summary_short")
        expect(by_subject["Untriaged"]["ai_summary_short"]).to be_nil
      end

      it "exposes the Jev triage label and priority, null until triaged" do
        create(:conversation, organization: org, subject: "Triaged", triage_label: "needs_answer", triage_priority: 3.2)
        create(:conversation, organization: org, subject: "Fresh")

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        by_subject = response.parsed_body["conversations"].index_by { |c| c["subject"] }
        expect(by_subject["Triaged"]).to include("triage_label" => "needs_answer", "triage_priority" => 3.2)
        expect(by_subject["Fresh"]).to include("triage_label" => nil, "triage_priority" => nil)
        expect(by_subject["Triaged"]).not_to have_key("triage_source")
      end

      it "exposes the Lore to-do title on list rows, the detail and the sync payload, null until written" do
        conv = create(:conversation, organization: org, subject: "Uw factuur", next_action_title: "Pay the Privium invoice")
        create(:conversation, organization: org, subject: "Untitled")

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        by_subject = response.parsed_body["conversations"].index_by { |c| c["subject"] }
        expect(by_subject["Uw factuur"]["next_action_title"]).to eq("Pay the Privium invoice")
        expect(by_subject["Untitled"]).to include("next_action_title" => nil)

        get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: headers
        expect(response.parsed_body.dig("conversation", "next_action_title")).to eq("Pay the Privium invoice")
        expect(Sync::ConversationSerializer.new(conv).to_h["next_action_title"]).to eq("Pay the Privium invoice")
      end

      it "orders by updated_at descending" do
        old = create(:conversation, organization: org, subject: "Old", updated_at: 2.days.ago)
        recent = create(:conversation, organization: org, subject: "Recent", updated_at: 1.hour.ago)

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        body = response.parsed_body
        expect(body["conversations"].first["subject"]).to eq("Recent")
      end

      it "filters by status" do
        create(:conversation, organization: org, status: "open")
        create(:conversation, organization: org, status: "archived")

        get "/api/v1/orgs/#{org.key}/conversations", params: { status: "open" }, headers: headers
        body = response.parsed_body
        expect(body["conversations"].length).to eq(1)
        expect(body["conversations"].first["status"]).to eq("open")
      end

      # A thread trashed/spammed/archived on any client must not resurface in a
      # client that lists the inbox without a status filter (iOS/Android).
      it "excludes trashed/spam/archived threads from the default listing" do
        visible = create(:conversation, organization: org, status: "open", subject: "Visible")
        create(:conversation, organization: org, status: "trash", subject: "Trashed")
        create(:conversation, organization: org, status: "spam", subject: "Spammy")
        create(:conversation, organization: org, status: "archived", subject: "Archived")

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        body = response.parsed_body
        expect(body["conversations"].map { |c| c["id"] }).to eq([visible.key])
      end

      it "still returns a hidden folder when its status is requested explicitly" do
        create(:conversation, organization: org, status: "open", subject: "Open one")
        trashed = create(:conversation, organization: org, status: "trash", subject: "Trashed one")

        get "/api/v1/orgs/#{org.key}/conversations", params: { status: "trash" }, headers: headers
        body = response.parsed_body
        expect(body["conversations"].map { |c| c["id"] }).to eq([trashed.key])
      end

      it "filters by read/unread" do
        create(:conversation, organization: org, read: true)
        create(:conversation, organization: org, read: false)

        get "/api/v1/orgs/#{org.key}/conversations", params: { read: "false" }, headers: headers
        body = response.parsed_body
        expect(body["conversations"].length).to eq(1)
        expect(body["conversations"].first["read"]).to eq(false)
      end

      it "filters by space" do
        support = create(:space, organization: org, slug: "support", name: "Support")
        sales = create(:space, organization: org, slug: "sales", name: "Sales")
        create(:conversation, organization: org, space: support, subject: "A support thread")
        create(:conversation, organization: org, space: sales, subject: "A sales thread")

        get "/api/v1/orgs/#{org.key}/conversations", params: { space: support.key }, headers: headers
        body = response.parsed_body
        expect(body["conversations"].length).to eq(1)
        expect(body["conversations"].first["subject"]).to eq("A support thread")
        expect(body["conversations"].first["space"]["slug"]).to eq("support")
      end

      it "returns nothing for an unknown space key (no unfiltered leak)" do
        create(:conversation, organization: org)

        get "/api/v1/orgs/#{org.key}/conversations", params: { space: "spc_nonexistent" }, headers: headers
        expect(response.parsed_body["conversations"]).to eq([])
      end

      it "filters by domain (per-domain workspace tab)" do
        d1 = create(:domain, organization: org, name: "one.example")
        d2 = create(:domain, organization: org, name: "two.example")
        create(:conversation, organization: org, domain: d1, subject: "Domain one thread")
        create(:conversation, organization: org, domain: d2, subject: "Domain two thread")

        get "/api/v1/orgs/#{org.key}/conversations", params: { domain: d1.key }, headers: headers
        body = response.parsed_body
        expect(body["conversations"].length).to eq(1)
        expect(body["conversations"].first["subject"]).to eq("Domain one thread")
      end

      it "returns nothing for an unknown domain key (no unfiltered leak)" do
        create(:conversation, organization: org)

        get "/api/v1/orgs/#{org.key}/conversations", params: { domain: "dom_nonexistent" }, headers: headers
        expect(response.parsed_body["conversations"]).to eq([])
      end

      it "exposes a thread's space (or null) in the response" do
        support = create(:space, organization: org, slug: "support", name: "Support")
        create(:conversation, organization: org, space: support)
        create(:conversation, organization: org, space: nil)

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        spaces = response.parsed_body["conversations"].map { |c| c["space"] }
        expect(spaces).to include(nil)
        placed = spaces.compact.first
        expect(placed["slug"]).to eq("support")
        expect(placed["id"]).to start_with("spc_")
      end

      it "includes tags in the response" do
        conv = create(:conversation, organization: org)
        tag = create(:tag, organization: org, name: "Important")
        conv.tags << tag

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        body = response.parsed_body
        expect(body["conversations"].first["tags"].first["name"]).to eq("Important")
      end

      # Sidebar LABELS — narrow to threads carrying the named tag (spec 6.2.2).
      it "filters by a single tag name" do
        vip = create(:conversation, organization: org, subject: "VIP thread")
        vip.tags << create(:tag, organization: org, name: "VIP")
        create(:conversation, organization: org, subject: "Untagged thread")

        get "/api/v1/orgs/#{org.key}/conversations", params: { tag: "VIP" }, headers: headers
        body = response.parsed_body
        expect(body["conversations"].length).to eq(1)
        expect(body["conversations"].first["subject"]).to eq("VIP thread")
      end

      # Labels are OR'd among themselves: tags[]=Billing&tags[]=Dev returns
      # threads carrying either, each once (no duplication when both match).
      it "filters by multiple tags (OR), AND-ed with the folder" do
        billing = create(:tag, organization: org, name: "Billing")
        dev = create(:tag, organization: org, name: "Dev")
        c_billing = create(:conversation, organization: org, status: "open", subject: "Billing only")
        c_billing.tags << billing
        c_both = create(:conversation, organization: org, status: "open", subject: "Both labels")
        c_both.tags << [billing, dev]
        create(:conversation, organization: org, status: "open", subject: "No labels")
        archived = create(:conversation, organization: org, status: "archived", subject: "Archived billing")
        archived.tags << billing

        get "/api/v1/orgs/#{org.key}/conversations",
            params: { status: "open", tags: %w[Billing Dev] }, headers: headers
        subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
        expect(subjects).to contain_exactly("Billing only", "Both labels")
      end

      # Sent folder — threads with a delivered outbound message (spec 3.4.1).
      it "filters by direction=outbound (Sent)" do
        sent = create(:conversation, organization: org, subject: "We replied")
        create(:message, conversation: sent, organization: org, is_inbound: false, is_draft: false)
        inbound_only = create(:conversation, organization: org, subject: "Only inbound")
        create(:message, conversation: inbound_only, organization: org, is_inbound: true)

        get "/api/v1/orgs/#{org.key}/conversations", params: { direction: "outbound" }, headers: headers
        body = response.parsed_body
        subjects = body["conversations"].map { |c| c["subject"] }
        expect(subjects).to include("We replied")
        expect(subjects).not_to include("Only inbound")
      end

      it "keeps a thread nothing has come in on out of the Inbox, but in Sent and Lore" do
        sent = create(:conversation, organization: org, subject: "Only sent", triage_label: TriageLabel::WAITING_REPLY)
        create(:message, conversation: sent, organization: org, is_inbound: false, is_draft: false)
        expect(sent.reload).to have_attributes(sent_only: true, read: true)

        list = lambda do |extra|
          get "/api/v1/orgs/#{org.key}/conversations", params: extra, headers: headers
          response.parsed_body["conversations"].map { |c| c["subject"] }
        end
        expect(list.call({ status: "open" })).not_to include("Only sent")
        expect(list.call({})).not_to include("Only sent")
        expect(list.call({ direction: "outbound" })).to include("Only sent")
        expect(list.call({ status: "open", triage_label: [TriageLabel::WAITING_REPLY] })).to include("Only sent")
        expect(list.call({ include_sent: "true" })).to include("Only sent")

        create(:message, conversation: sent.reload, organization: org, is_inbound: true)
        expect(sent.reload).to have_attributes(sent_only: false, read: false)
        expect(list.call({ status: "open" })).to include("Only sent")
      end

      it "keeps a sent-only thread in Lore's per-member lists" do
        sent = create(:conversation, organization: org, subject: "Only sent", triage_label: TriageLabel::FYI)
        create(:message, conversation: sent, organization: org, is_inbound: false, is_draft: false)
        list = lambda do |lore_done|
          get "/api/v1/orgs/#{org.key}/conversations", params: { lore_done: lore_done }, headers: headers
          response.parsed_body["conversations"].map { |c| c["subject"] }
        end
        expect(list.call("false")).to include("Only sent")

        post "/api/v1/orgs/#{org.key}/conversations/bulk",
             params: { conversation_ids: [sent.key], action_name: LoreMemberDone::ACTION_DONE }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(list.call("true")).to include("Only sent")
      end

      it "puts a thread back when the only send is undone to a draft" do
        sent = create(:conversation, organization: org)
        message = create(:message, conversation: sent, organization: org, is_inbound: false, is_draft: false)
        message.update!(is_draft: true)
        expect(sent.reload).to have_attributes(sent_only: false, read: true)
      end

      it "keeps sent-only threads out of the Mine and Unassigned Inbox views" do
        sent = create(:conversation, organization: org, subject: "Only sent")
        create(:message, conversation: sent, organization: org, is_inbound: false, is_draft: false)

        get "/api/v1/orgs/#{org.key}/conversations", params: { assignee: "none" }, headers: headers
        expect(response.parsed_body["conversations"].map { |c| c["subject"] }).not_to include("Only sent")
      end

      it "recomputes sent_only when a merge brings a reply into a sent thread" do
        sent = create(:conversation, organization: org)
        create(:message, conversation: sent, organization: org, is_inbound: false, is_draft: false)
        other = create(:conversation, organization: org)
        create(:message, conversation: other, organization: org, is_inbound: true)

        post "/api/v1/orgs/#{org.key}/conversations/#{other.key}/merge", params: { target_id: sent.key }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(sent.reload).to have_attributes(sent_only: false, read: false)
      end

      it "recomputes sent_only on both sides of a split" do
        thread = create(:conversation, organization: org)
        create(:message, conversation: thread, organization: org, is_inbound: true)
        sent = create(:message, conversation: thread, organization: org, is_inbound: false, is_draft: false)

        post "/api/v1/orgs/#{org.key}/conversations/#{thread.key}/split", params: { message_id: sent.key }, headers: headers
        expect(response).to have_http_status(:created)
        expect(Conversation.find_by!(key: response.parsed_body.dig("conversation", "id")).sent_only).to be(true)
        expect(thread.reload.sent_only).to be(false)
      end

      it "excludes draft-only threads from direction=outbound" do
        draft_only = create(:conversation, organization: org, subject: "Just a draft")
        create(:message, conversation: draft_only, organization: org, is_inbound: false, is_draft: true)

        get "/api/v1/orgs/#{org.key}/conversations", params: { direction: "outbound" }, headers: headers
        subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
        expect(subjects).not_to include("Just a draft")
      end

      # Assignee filter — the system views (Inbox = mine, Unassigned) (spec 3.4.1).
      it "filters by assignee=me" do
        mine = create(:conversation, organization: org, subject: "Mine")
        mine.assignees = [owner_membership]
        create(:conversation, organization: org, subject: "Someone else's")

        get "/api/v1/orgs/#{org.key}/conversations", params: { assignee: "me" }, headers: headers
        subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
        expect(subjects).to eq(["Mine"])
      end

      it "lists each thread's assignees compactly" do
        conv = create(:conversation, organization: org, subject: "Assigned")
        conv.assignees = [owner_membership]
        create(:conversation, organization: org, subject: "Nobody's")

        get "/api/v1/orgs/#{org.key}/conversations", headers: headers
        by_subject = response.parsed_body["conversations"].index_by { |c| c["subject"] }
        expect(by_subject["Assigned"]["assignees"]).to eq([
          { "id" => owner_membership.key, "name" => owner.display_name.presence || owner.username }
        ])
        expect(by_subject["Nobody's"]["assignees"]).to eq([])
      end

      it "filters by assignee=none (Unassigned)" do
        assigned = create(:conversation, organization: org, subject: "Assigned")
        assigned.assignees = [owner_membership]
        create(:conversation, organization: org, subject: "Nobody's")

        get "/api/v1/orgs/#{org.key}/conversations", params: { assignee: "none" }, headers: headers
        subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
        expect(subjects).to eq(["Nobody's"])
      end

      # Drafts folder — threads with an unsent draft message (spec 3.4.1).
      it "filters by is_draft=true (Drafts)" do
        with_draft = create(:conversation, organization: org, subject: "Has a draft")
        create(:message, conversation: with_draft, organization: org, is_inbound: false, is_draft: true, owner_membership_id: owner_membership.id)
        sent_only = create(:conversation, organization: org, subject: "Sent only")
        create(:message, conversation: sent_only, organization: org, is_inbound: false, is_draft: false)

        get "/api/v1/orgs/#{org.key}/conversations", params: { is_draft: "true" }, headers: headers
        subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
        expect(subjects).to include("Has a draft")
        expect(subjects).not_to include("Sent only")
      end

      # Mentioned folder — threads with a mention notification for the caller.
      it "filters by mentioned=me (Mentioned)" do
        mentioned = create(:conversation, organization: org, subject: "You were mentioned")
        Notification.create!(organization: org, user: owner, conversation: mentioned,
                             kind: Notification::KIND_MENTION, title: "mention")
        create(:conversation, organization: org, subject: "Not mentioned")

        get "/api/v1/orgs/#{org.key}/conversations", params: { mentioned: "me" }, headers: headers
        subjects = response.parsed_body["conversations"].map { |c| c["subject"] }
        expect(subjects).to eq(["You were mentioned"])
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a different org" do
        other_user = create(:user, username: "convother")
        other_org = create(:organization, owner: other_user, domain: "convother.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        create(:conversation, organization: other_org, subject: "Secret")

        get "/api/v1/orgs/#{other_org.key}/conversations", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — unauthorized" do
      it "rejects unauthenticated request" do
        get "/api/v1/orgs/#{org.key}/conversations"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    describe "triage_label filter" do
      let(:path) { "/api/v1/orgs/#{org.key}/conversations" }
      def subjects = response.parsed_body["conversations"].map { |c| c["subject"] }.sort

      before do
        create(:conversation, organization: org, subject: "Reply", triage_label: "needs_reply")
        create(:conversation, organization: org, subject: "FYI", triage_label: "fyi")
        create(:conversation, organization: org, subject: "Promo", triage_label: "promotion")
        create(:conversation, organization: org, subject: "Untriaged", triage_label: nil)
      end

      context "positive" do
        it "filters by a single label" do
          get path, params: { triage_label: "fyi" }, headers: headers
          expect(subjects).to eq(["FYI"])
        end

        it "labeled=true keeps every labelled thread but resolved, custom labels included" do
          create(:conversation, organization: org, subject: "Done", triage_label: "resolved")
          get path, params: { labeled: "true" }, headers: headers
          expect(subjects).to eq(%w[FYI Promo Reply])
        end

        it "filters by any of several labels (array form), ignoring blanks" do
          get path, params: { triage_label: ["needs_reply", "fyi", ""] }, headers: headers
          expect(subjects).to eq(%w[FYI Reply])
        end

        it "is AND-ed with the other filters" do
          get path, params: { triage_label: %w[fyi needs_reply], status: "open" }, headers: headers
          expect(subjects).to eq(%w[FYI Reply])
          get path, params: { triage_label: "fyi", status: "closed" }, headers: headers
          expect(subjects).to eq([])
        end
      end

      context "negative" do
        it "returns everything without the param, or with only blanks" do
          get path, headers: headers
          expect(subjects).to eq(%w[FYI Promo Reply Untriaged])
          get path, params: { triage_label: "" }, headers: headers
          expect(subjects).to eq(%w[FYI Promo Reply Untriaged])
        end

        it "returns an empty list for an unknown label" do
          get path, params: { triage_label: "no_such_label" }, headers: headers
          expect(response).to have_http_status(:ok)
          expect(subjects).to eq([])
        end

        it "never leaks another org's threads (E3)" do
          other_user = create(:user, username: "triageother")
          other_org = create(:organization, owner: other_user, domain: "triageother.com")
          create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
          create(:conversation, organization: other_org, subject: "Secret", triage_label: "fyi")

          get path, params: { triage_label: "fyi" }, headers: headers
          expect(subjects).to eq(["FYI"])
          get "/api/v1/orgs/#{other_org.key}/conversations", params: { triage_label: "fyi" }, headers: headers
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    context "pagination (spec 3.4.6, BaseController#paginate)" do
      it "returns the page slice and meta, defaulting per_page to 25" do
        create_list(:conversation, 3, organization: org)

        get "/api/v1/orgs/#{org.key}/conversations", params: { per_page: 2, page: 1 }, headers: headers
        body = response.parsed_body
        expect(body["conversations"].length).to eq(2)
        expect(body["meta"]).to eq("page" => 1, "per_page" => 2, "total" => 3)

        get "/api/v1/orgs/#{org.key}/conversations", params: { per_page: 2, page: 2 }, headers: headers
        expect(response.parsed_body["conversations"].length).to eq(1)
        expect(response.parsed_body["meta"]["page"]).to eq(2)
      end

      it "clamps per_page to the 1..100 range and floors page at 1" do
        get "/api/v1/orgs/#{org.key}/conversations", params: { per_page: 9999, page: 0 }, headers: headers
        meta = response.parsed_body["meta"]
        expect(meta["per_page"]).to eq(100)
        expect(meta["page"]).to eq(1)
      end
    end
  end

  # --- Spec 3.1.4, 4.1.1, A6.2 — Show conversation ---
  describe "GET /api/v1/orgs/:org_id/conversations/:id" do
    context "positive" do
      it "returns the conversation with messages" do
        conv = create(:conversation, organization: org, subject: "Thread details")
        create(:message, conversation: conv, organization: org, body_plain: "Hello!")
        create(:message, conversation: conv, organization: org, body_plain: "Reply here")

        get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["conversation"]["subject"]).to eq("Thread details")
        expect(body["conversation"]["messages"].length).to eq(2)
        body["conversation"]["messages"].each do |m|
          expect(m["id"]).to start_with("msg_")
          expect(m).not_to have_key("organization_id")
          # conversation_id is exposed as the public thread key (E5), not the FK.
          expect(m["conversation_id"]).to eq(conv.key)
        end
      end

      # The reader's Triage menu checks the current Space and label.
      it "includes the triage label, priority and Space" do
        space = create(:space, organization: org, slug: "support", name: "Support")
        conv = create(:conversation, organization: org, space: space, triage_label: "needs_answer", triage_priority: 3.0)

        get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: headers
        body = response.parsed_body["conversation"]
        expect(body["triage_label"]).to eq("needs_answer")
        expect(body["triage_priority"]).to eq(3.0)
        expect(body["space"]).to include("id" => space.key, "slug" => "support")
      end

      it "includes tags" do
        conv = create(:conversation, organization: org)
        tag = create(:tag, organization: org, name: "VIP")
        conv.tags << tag

        get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: headers
        body = response.parsed_body
        expect(body["conversation"]["tags"].first["name"]).to eq("VIP")
      end

      # Collaboration read path (spec 5.2.1 / 5.3.1) — assignees + notes so a client
      # can display, not just set, them.
      it "includes assignees" do
        conv = create(:conversation, organization: org)
        conv.assignees = [owner_membership]

        get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: headers
        body = response.parsed_body
        expect(body["conversation"]["assignees"].length).to eq(1)
        expect(body["conversation"]["assignees"].first["user"]["id"]).to eq(owner.key)
      end

      it "includes notes" do
        conv = create(:conversation, organization: org)
        create(:note, conversation: conv, organization: org, membership: owner_membership, body: "Follow up Monday")

        get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: headers
        body = response.parsed_body
        expect(body["conversation"]["notes"].length).to eq(1)
        expect(body["conversation"]["notes"].first["body"]).to eq("Follow up Monday")
      end
    end

    context "negative — not found" do
      it "returns 404 for nonexistent conversation" do
        get "/api/v1/orgs/#{org.key}/conversations/conv_nonexistent", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a conversation in another org" do
        other_user = create(:user, username: "conviso")
        other_org = create(:organization, owner: other_user, domain: "conviso.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        other_conv = create(:conversation, organization: other_org)

        get "/api/v1/orgs/#{org.key}/conversations/#{other_conv.key}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Spec 4.2.2, 4.2.6, 6.1.2, A6.3 — Update conversation ---
  describe "PATCH /api/v1/orgs/:org_id/conversations/:id" do
    let!(:conv) { create(:conversation, organization: org, status: "open", read: false) }

    context "positive" do
      it "updates status" do
        patch "/api/v1/orgs/#{org.key}/conversations/#{conv.key}",
              params: { status: "archived" },
              headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversation"]["status"]).to eq("archived")
      end

      it "marks as read" do
        patch "/api/v1/orgs/#{org.key}/conversations/#{conv.key}",
              params: { read: true },
              headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversation"]["read"]).to eq(true)
      end
    end

    context "negative — invalid status" do
      it "rejects invalid status value" do
        patch "/api/v1/orgs/#{org.key}/conversations/#{conv.key}",
              params: { status: "invalid" },
              headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a conversation in another org" do
        other_user = create(:user, username: "convpatch")
        other_org = create(:organization, owner: other_user, domain: "convpatch.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        other_conv = create(:conversation, organization: other_org)

        patch "/api/v1/orgs/#{org.key}/conversations/#{other_conv.key}",
              params: { status: "archived" },
              headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Spec 6.2.2, A9.2 — Update conversation tags ---
  describe "PUT /api/v1/orgs/:org_id/conversations/:id/tags" do
    let!(:conv) { create(:conversation, organization: org) }
    let!(:tag1) { create(:tag, organization: org, name: "Billing") }
    let!(:tag2) { create(:tag, organization: org, name: "Urgent") }

    context "positive" do
      it "applies tags to a conversation" do
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags",
            params: { tag_ids: [tag1.key, tag2.key] },
            headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["conversation"]["tags"].length).to eq(2)
      end

      it "replaces existing tags" do
        conv.tags << tag1
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags",
            params: { tag_ids: [tag2.key] },
            headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["conversation"]["tags"].length).to eq(1)
        expect(body["conversation"]["tags"].first["name"]).to eq("Urgent")
      end

      it "adds and removes single tags without touching the rest" do
        conv.tags << tag1
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags",
            params: { add_tag_ids: [tag2.key] }, headers: headers
        expect(conv.reload.tags).to contain_exactly(tag1, tag2)
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags",
            params: { remove_tag_ids: [tag1.key] }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(conv.reload.tags).to contain_exactly(tag2)
      end

      it "removes all tags when empty array" do
        conv.tags << tag1
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags",
            params: { tag_ids: [] },
            headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversation"]["tags"]).to eq([])
      end

      # Regression: an Eisenhower-matrix placement is persisted purely as the
      # presence of priority tags. Every quadrant — including "Later", which has
      # no Urgent/Important flag — must survive a re-read of the conversation
      # list, or the card silently vanishes on refresh.
      it "round-trips every quadrant's priority tags through the index" do
        Tag.ensure_system_tags(org)
        keys = org.tags.where(name: %w[Urgent Important Later])
                       .index_by(&:name).transform_values(&:key)

        quadrants = {
          "Priority" => [keys["Urgent"], keys["Important"]],
          "Delegate" => [keys["Urgent"]],
          "Schedule" => [keys["Important"]],
          "Later"    => [keys["Later"]]
        }

        quadrants.each_value do |tag_ids|
          put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags",
              params: { tag_ids: tag_ids }, headers: headers
          expect(response).to have_http_status(:ok)

          # Re-read via the list endpoint the matrix loads from on refresh.
          get "/api/v1/orgs/#{org.key}/conversations", headers: headers
          row = response.parsed_body["conversations"].find { |c| c["id"] == conv.key }
          expect(row["tags"].map { |t| t["name"] }).to match_array(
            tag_ids.map { |k| org.tags.find_by!(key: k).name }
          )
        end
      end
    end

    context "negative — tenant isolation (E3)" do
      it "ignores tags from another org" do
        other_user = create(:user, username: "tagthief")
        other_org = create(:organization, owner: other_user, domain: "tagthief.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        foreign_tag = create(:tag, organization: other_org, name: "Foreign")

        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/tags",
            params: { tag_ids: [foreign_tag.key] },
            headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversation"]["tags"]).to eq([])
      end
    end
  end

  describe "PUT /api/v1/orgs/:org_id/conversations/:id/space" do
    let!(:conv) { create(:conversation, organization: org) }
    let!(:support) { create(:space, organization: org, slug: "support", name: "Support") }
    let!(:triage) { create(:space, organization: org, slug: "triage", name: "Triage", classify: false) }

    context "positive" do
      it "moves a conversation into a space" do
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/space",
            params: { space_id: support.key }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversation"]["space"]["slug"]).to eq("support")
        expect(conv.reload.space).to eq(support)
      end

      it "allows moving into the Triage holding pen (any org space is a valid target)" do
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/space",
            params: { space_id: triage.key }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(conv.reload.space).to eq(triage)
      end

      it "clears the space when space_id is blank" do
        conv.update!(space: support)
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/space",
            params: { space_id: "" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversation"]["space"]).to be_nil
        expect(conv.reload.space).to be_nil
      end
    end

    context "negative — tenant isolation (E3)" do
      it "404s for a space from another org and leaves the thread untouched" do
        conv.update!(space: support)
        other_user = create(:user, username: "spacethief")
        other_org = create(:organization, owner: other_user, domain: "spacethief.com")
        foreign_space = create(:space, organization: other_org, slug: "foreign")

        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/space",
            params: { space_id: foreign_space.key }, headers: headers
        expect(response).to have_http_status(:not_found)
        expect(conv.reload.space).to eq(support)
      end
    end
  end

  # Manual triage — docs/Triage.md "Manual triage"
  describe "PUT /api/v1/orgs/:org_id/conversations/:id/triage-label" do
    let!(:conv) { create(:conversation, organization: org, triage_label: "fyi", triage_source: "jev:jev-1.13.0") }
    let(:path) { "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/triage-label" }

    context "positive" do
      it "sets a built-in label with manual provenance" do
        put path, params: { label: "needs_answer" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["conversation"]["triage_label"]).to eq("needs_answer")
        expect(conv.reload.triage_source).to eq(TriageLabel::SOURCE_MANUAL)
      end

      it "accepts an enabled custom label" do
        TriageLabel.ensure_defaults(org)
        org.triage_labels.create!(slug: "invoices", name: "Invoices", description: "Bills", position: 20)
        put path, params: { label: "invoices" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(conv.reload.triage_label).to eq("invoices")
      end
    end

    context "negative" do
      it "422s for an unknown label and leaves the thread untouched" do
        put path, params: { label: "nope" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["errors"]).to be_present
        expect(conv.reload.triage_label).to eq("fyi")
      end

      it "422s for a missing label" do
        put path, params: {}, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "422s for a disabled label" do
        TriageLabel.ensure_defaults(org)
        org.triage_labels.find_by!(slug: "resolved").update!(enabled: false)
        put path, params: { label: "resolved" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(conv.reload.triage_label).to eq("fyi")
      end

      it "401s without auth" do
        put path, params: { label: "needs_answer" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "404s for another org's conversation" do
        other_user = create(:user, username: "labelthief")
        other_org = create(:organization, owner: other_user, domain: "labelthief.com")
        foreign = create(:conversation, organization: other_org, triage_label: "fyi")

        put "/api/v1/orgs/#{org.key}/conversations/#{foreign.key}/triage-label",
            params: { label: "needs_answer" }, headers: headers
        expect(response).to have_http_status(:not_found)
        expect(foreign.reload.triage_label).to eq("fyi")
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/conversations/:id/retriage" do
    let!(:conv) { create(:conversation, organization: org, status: Conversation::STATUS_OPEN) }
    let(:path) { "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/retriage" }

    before do
      org.update!(plan: create(:plan, ai_triage: true, tier: Plan::TIER_PAID))
      allow(SpaceClassifier).to receive(:enabled?).and_return(true)
      create(:message, conversation: conv, organization: org, is_inbound: true)
    end

    context "positive" do
      it "enqueues a re-triage without the new-thread push and returns 202" do
        expect { post path, headers: headers }
          .to have_enqueued_job(ClassifySpaceJob).with(conv.id, false)
        expect(response).to have_http_status(:accepted)
        expect(response.parsed_body["conversation"]["id"]).to eq(conv.key)
      end
    end

    context "negative" do
      it "422s when the org's plan has no AI triage" do
        org.update!(plan: create(:plan, ai_triage: false))
        expect { post path, headers: headers }.not_to have_enqueued_job(ClassifySpaceJob)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "422s when no triage provider is configured" do
        allow(SpaceClassifier).to receive(:enabled?).and_return(false)
        expect { post path, headers: headers }.not_to have_enqueued_job(ClassifySpaceJob)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "422s for an archived thread (the job would no-op)" do
        conv.update!(status: Conversation::STATUS_ARCHIVED)
        expect { post path, headers: headers }.not_to have_enqueued_job(ClassifySpaceJob)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "422s for a sealed thread (no plaintext to re-read)" do
        conv.messages.delete_all
        create(:message, conversation: conv, organization: org, is_inbound: true,
          encryption_scheme: Message::ENCRYPTION_SCHEME_SEALED_BOX_V1,
          from_address: nil, subject: nil, body_plain: nil, body_html: nil,
          message_id_header: nil, sealed_dek: "blob", body_ciphertext: "ct", header_ciphertext: "ct")
        expect { post path, headers: headers }.not_to have_enqueued_job(ClassifySpaceJob)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "429s when the org's monthly triage cap is reached" do
        allow_any_instance_of(TriageBreaker).to receive(:allow?).and_return(false)
        expect { post path, headers: headers }.not_to have_enqueued_job(ClassifySpaceJob)
        expect(response).to have_http_status(:too_many_requests)
      end

      it "404s for another org's conversation (E3)" do
        other_org = create(:organization, owner: create(:user, username: "retriagethief"), domain: "retriagethief.com")
        foreign = create(:conversation, organization: other_org)
        post "/api/v1/orgs/#{org.key}/conversations/#{foreign.key}/retriage", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Spec 3.4.3, A6.4 — Bulk actions ---
  describe "POST /api/v1/orgs/:org_id/conversations/bulk" do
    let!(:conv1) { create(:conversation, organization: org, status: "open") }
    let!(:conv2) { create(:conversation, organization: org, status: "open") }

    context "positive" do
      it "archives multiple conversations" do
        post "/api/v1/orgs/#{org.key}/conversations/bulk",
             params: { conversation_ids: [conv1.key, conv2.key], action_name: "archive" },
             headers: headers
        expect(response).to have_http_status(:ok)
        expect(conv1.reload.status).to eq("archived")
        expect(conv2.reload.status).to eq("archived")
      end

      it "permanently deletes only the threads already in trash or spam" do
        conv1.update!(status: "trash")
        post "/api/v1/orgs/#{org.key}/conversations/bulk",
             params: { conversation_ids: [conv1.key, conv2.key], action_name: "delete" },
             headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["updated"]).to eq(1)
        expect(Conversation.exists?(conv1.id)).to be(false)
        expect(conv2.reload.status).to eq("open")
      end

      it "marks multiple conversations as read" do
        post "/api/v1/orgs/#{org.key}/conversations/bulk",
             params: { conversation_ids: [conv1.key], action_name: "mark_read" },
             headers: headers
        expect(response).to have_http_status(:ok)
        expect(conv1.reload.read).to eq(true)
      end

      # spec 11.1.3 — "mark as spam" from any client goes through bulk, so this is
      # the path that has to train Bayes (the spam-feedback endpoint isn't wired
      # into any UI).
      it "trains Rspamd spam on bulk spam" do
        create(:message, conversation: conv1, organization: org, is_inbound: true, body_plain: "Buy now")
        client = instance_double(RspamdClient)
        allow(RspamdClient).to receive(:new).and_return(client)
        expect(client).to receive(:train_spam)

        perform_enqueued_jobs do
          post "/api/v1/orgs/#{org.key}/conversations/bulk",
               params: { conversation_ids: [conv1.key], action_name: "spam" },
               headers: headers
        end
        expect(conv1.reload.status).to eq("spam")
      end

      it "trains Rspamd ham when a thread is released from spam back to the inbox" do
        conv1.update!(status: "spam")
        create(:message, conversation: conv1, organization: org, is_inbound: true, body_plain: "Real mail")
        client = instance_double(RspamdClient)
        allow(RspamdClient).to receive(:new).and_return(client)
        expect(client).to receive(:train_ham)

        perform_enqueued_jobs do
          post "/api/v1/orgs/#{org.key}/conversations/bulk",
               params: { conversation_ids: [conv1.key], action_name: "open" },
               headers: headers
        end
        expect(conv1.reload.status).to eq("open")
      end

      # The bug: marking spam on the desktop left the iPhone's app-icon badge
      # stale until the app was reopened. Every bulk action that moves the MX
      # unread pool has to push a fresh badge to the user's other devices —
      # including mark_read, which sent no push at all.
      %w[spam trash archive mark_read mark_unread open].each do |bulk_action|
        it "pushes a badge refresh on bulk #{bulk_action}" do
          allow(RspamdClient).to receive(:new).and_return(instance_double(RspamdClient, train_spam: true, train_ham: true))
          expect(MobilePushSender).to receive(:refresh_badge_for_org).with(org).at_least(:once)

          # The fan-out rides MobileBadgeRefreshJob now — perform it inline.
          perform_enqueued_jobs do
            post "/api/v1/orgs/#{org.key}/conversations/bulk",
                 params: { conversation_ids: [conv1.key], action_name: bulk_action },
                 headers: headers
          end
          expect(response).to have_http_status(:ok)
        end
      end

      it "still applies the action when the badge push raises" do
        allow(MobilePushSender).to receive(:refresh_badge_for_org).and_raise(StandardError, "apns down")

        perform_enqueued_jobs do
          post "/api/v1/orgs/#{org.key}/conversations/bulk",
               params: { conversation_ids: [conv1.key], action_name: "mark_read" },
               headers: headers
        end
        expect(response).to have_http_status(:ok)
        expect(conv1.reload.read).to eq(true)
      end

      # Bayes needs 50 learns per class before it scores anything, so training
      # alone left the NEXT mail from the same sender landing in the inbox.
      it "junk-lists the sender on bulk spam" do
        create(:message, conversation: conv1, organization: org, is_inbound: true, from_address: "Security@FacebookMail.com")
        allow(RspamdClient).to receive(:new).and_return(instance_double(RspamdClient, train_spam: true))

        perform_enqueued_jobs do
          post "/api/v1/orgs/#{org.key}/conversations/bulk",
               params: { conversation_ids: [conv1.key], action_name: "spam" },
               headers: headers
        end

        expect(org.mail_filters.where(kind: MailFilter::KIND_JUNK).pluck(:value)).to eq(["security@facebookmail.com"])
      end

      it "un-junks the sender when the thread is released back to the inbox" do
        conv1.update!(status: "spam")
        create(:message, conversation: conv1, organization: org, is_inbound: true, from_address: "security@facebookmail.com")
        MailFilter.create!(organization: org, kind: MailFilter::KIND_JUNK, value: "security@facebookmail.com")
        allow(RspamdClient).to receive(:new).and_return(instance_double(RspamdClient, train_ham: true))

        perform_enqueued_jobs do
          post "/api/v1/orgs/#{org.key}/conversations/bulk",
               params: { conversation_ids: [conv1.key], action_name: "open" },
               headers: headers
        end

        expect(org.mail_filters.where(kind: MailFilter::KIND_JUNK)).to be_empty
      end

      it "never junk-lists a sender on one of the org's own domains" do
        create(:message, conversation: conv1, organization: org, is_inbound: true, from_address: "colleague@#{org.domains.first.name}")
        allow(RspamdClient).to receive(:new).and_return(instance_double(RspamdClient, train_spam: true))

        perform_enqueued_jobs do
          post "/api/v1/orgs/#{org.key}/conversations/bulk",
               params: { conversation_ids: [conv1.key], action_name: "spam" },
               headers: headers
        end

        expect(org.mail_filters.where(kind: MailFilter::KIND_JUNK)).to be_empty
      end

      it "leaves an explicit allowlist entry alone" do
        create(:message, conversation: conv1, organization: org, is_inbound: true, from_address: "trusted@good.com")
        MailFilter.create!(organization: org, kind: MailFilter::KIND_ALLOWLIST, value: "trusted@good.com")
        allow(RspamdClient).to receive(:new).and_return(instance_double(RspamdClient, train_spam: true))

        perform_enqueued_jobs do
          post "/api/v1/orgs/#{org.key}/conversations/bulk",
               params: { conversation_ids: [conv1.key], action_name: "spam" },
               headers: headers
        end

        expect(org.mail_filters.pluck(:kind)).to eq([MailFilter::KIND_ALLOWLIST])
      end

      it "does not train when a non-spam thread is moved to the inbox" do
        conv1.update!(status: "archived")
        create(:message, conversation: conv1, organization: org, is_inbound: true, body_plain: "Real mail")
        expect(RspamdClient).not_to receive(:new)

        perform_enqueued_jobs do
          post "/api/v1/orgs/#{org.key}/conversations/bulk",
               params: { conversation_ids: [conv1.key], action_name: "open" },
               headers: headers
        end
        expect(conv1.reload.status).to eq("open")
      end
    end

    context "negative" do
      it "rejects unknown action" do
        post "/api/v1/orgs/#{org.key}/conversations/bulk",
             params: { conversation_ids: [conv1.key], action_name: "explode" },
             headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects empty conversation list" do
        post "/api/v1/orgs/#{org.key}/conversations/bulk",
             params: { conversation_ids: [], action_name: "archive" },
             headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "POST /api/v1/orgs/:org_id/conversations/empty" do
    let!(:spam1) { create(:conversation, organization: org, status: "spam") }
    let!(:spam2) { create(:conversation, organization: org, status: "spam") }
    let!(:trashed) { create(:conversation, organization: org, status: "trash") }
    let!(:open_conv) { create(:conversation, organization: org, status: "open") }

    context "positive" do
      it "permanently deletes every conversation in the spam folder" do
        post "/api/v1/orgs/#{org.key}/conversations/empty",
             params: { status: "spam" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["deleted"]).to eq(2)
        expect(Conversation.where(id: [spam1.id, spam2.id])).to be_empty
      end

      it "leaves other folders untouched" do
        post "/api/v1/orgs/#{org.key}/conversations/empty",
             params: { status: "spam" }, headers: headers
        expect(trashed.reload).to be_present
        expect(open_conv.reload).to be_present
      end

      it "empties the trash folder" do
        post "/api/v1/orgs/#{org.key}/conversations/empty",
             params: { status: "trash" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(Conversation.where(id: trashed.id)).to be_empty
      end
    end

    context "negative" do
      it "refuses to empty a non-disposable folder (archived)" do
        post "/api/v1/orgs/#{org.key}/conversations/empty",
             params: { status: "archived" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "refuses to empty the open inbox" do
        post "/api/v1/orgs/#{org.key}/conversations/empty",
             params: { status: "open" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
        expect(open_conv.reload).to be_present
      end

      it "does not touch another org's junk (tenant isolation)" do
        other_owner = create(:user, username: "otherjunkowner")
        other_org = create(:organization, owner: other_owner, domain: "otherjunk.com")
        other_spam = create(:conversation, organization: other_org, status: "spam")
        post "/api/v1/orgs/#{org.key}/conversations/empty",
             params: { status: "spam" }, headers: headers
        expect(other_spam.reload).to be_present
      end
    end
  end

  describe "GET /api/v1/orgs/:org_id/conversations/unread-count" do
    context "positive" do
      it "counts only open, unread conversations" do
        create(:conversation, organization: org, status: "open", read: false)
        create(:conversation, organization: org, status: "open", read: false)
        create(:conversation, organization: org, status: "open", read: true)
        create(:conversation, organization: org, status: "trash", read: false)
        create(:conversation, organization: org, status: "archived", read: false)

        get "/api/v1/orgs/#{org.key}/conversations/unread-count", headers: headers
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["unread_count"]).to eq(2)
      end

      it "counts the whole pool, not one page of it" do
        # The clients' badges used to count unread rows out of #index, whose page
        # is 25 — so every busy mailbox read as "25 unread" forever.
        create_list(:conversation, 30, organization: org, status: "open", read: false)

        get "/api/v1/orgs/#{org.key}/conversations/unread-count", headers: headers
        expect(JSON.parse(response.body)["unread_count"]).to eq(30)
      end

      it "narrows to one domain (per-domain workspace tab)" do
        d1 = create(:domain, organization: org, name: "one.example")
        d2 = create(:domain, organization: org, name: "two.example")
        create_list(:conversation, 2, organization: org, domain: d1, status: "open", read: false)
        create(:conversation, organization: org, domain: d2, status: "open", read: false)

        get "/api/v1/orgs/#{org.key}/conversations/unread-count",
            params: { domain: d1.key }, headers: headers
        expect(JSON.parse(response.body)["unread_count"]).to eq(2)
      end

      it "narrows to one space (Spaces drill-in)" do
        space = create(:space, organization: org)
        create(:conversation, organization: org, space: space, status: "open", read: false)
        create(:conversation, organization: org, status: "open", read: false)

        get "/api/v1/orgs/#{org.key}/conversations/unread-count",
            params: { space: space.key }, headers: headers
        expect(JSON.parse(response.body)["unread_count"]).to eq(1)
      end
    end

    context "negative" do
      it "does not leak another org's unread (tenant isolation)" do
        other_org = create(:organization, owner: create(:user, username: "otherowner"))
        create(:conversation, organization: other_org, status: "open", read: false)

        get "/api/v1/orgs/#{other_org.key}/conversations/unread-count", headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "counts nothing for an unknown domain key (no unfiltered leak)" do
        create(:conversation, organization: org, status: "open", read: false)

        get "/api/v1/orgs/#{org.key}/conversations/unread-count",
            params: { domain: "dom_nonexistent" }, headers: headers
        expect(JSON.parse(response.body)["unread_count"]).to eq(0)
      end
    end
  end

  # --- Spec 4.2.6, A6.5 — Archive / Trash / Spam ---
  describe "POST /api/v1/orgs/:org_id/conversations/:id/archive" do
    let!(:conv) { create(:conversation, organization: org, status: "open") }

    it "archives the conversation" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/archive", headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.status).to eq("archived")
    end

    it "returns 404 for tenant isolation (E3)" do
      other_user = create(:user, username: "archiveiso")
      other_org = create(:organization, owner: other_user, domain: "archiveiso.com")
      create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
      other_conv = create(:conversation, organization: other_org)

      post "/api/v1/orgs/#{org.key}/conversations/#{other_conv.key}/archive", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/orgs/:org_id/conversations/:id/trash" do
    let!(:conv) { create(:conversation, organization: org, status: "open") }

    it "trashes the conversation" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/trash", headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.status).to eq("trash")
    end

    it "fires a mobile removal push for the trashed conversation" do
      expect(MobilePushSender).to receive(:remove_for_org).with(org, [ conv.key ])
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/trash", headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "still trashes when the removal push raises" do
      allow(MobilePushSender).to receive(:remove_for_org).and_raise(StandardError, "apns down")
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/trash", headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.status).to eq("trash")
    end
  end

  # --- Spec 4.2.7, A6.6 — Snooze ---
  describe "POST /api/v1/orgs/:org_id/conversations/:id/snooze" do
    let!(:conv) { create(:conversation, organization: org, status: "open") }

    it "snoozes the conversation until the given time" do
      wake = 2.days.from_now
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/snooze",
           params: { until: wake.iso8601 }, headers: headers
      expect(response).to have_http_status(:ok)
      conv.reload
      expect(conv.status).to eq(Conversation::STATUS_PENDING)
      expect(conv.snoozed_until).to be_within(1.second).of(wake)
    end

    it "returns 422 for an unparseable until" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/snooze",
           params: { until: "not-a-time" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(conv.reload.status).to eq("open")
    end

    it "returns 422 when until is missing" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/snooze", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(conv.reload.status).to eq("open")
    end
  end

  describe "POST /api/v1/orgs/:org_id/conversations/:id/spam" do
    let!(:conv) { create(:conversation, organization: org, status: "open") }

    it "marks the conversation as spam" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/spam", headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.status).to eq("spam")
    end

    it "trains Rspamd on the spam verdict" do
      create(:message, conversation: conv, organization: org, is_inbound: true, body_plain: "Buy now")
      client = instance_double(RspamdClient)
      allow(RspamdClient).to receive(:new).and_return(client)
      expect(client).to receive(:train_spam)

      perform_enqueued_jobs do
        post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/spam", headers: headers
      end
      expect(response).to have_http_status(:ok)
    end
  end

  # --- Spec 4.1.5, A6.10 — Raw message source ---
  describe "GET /api/v1/orgs/:org_id/conversations/:id/raw/:message_id" do
    let!(:conv) { create(:conversation, organization: org) }
    let!(:msg) do
      create(:message, conversation: conv, organization: org,
             message_id_header: "<test123@example.com>",
             in_reply_to: "<parent@example.com>",
             references_header: "<parent@example.com>",
             body_plain: "Raw body",
             body_html: "<p>Raw body</p>")
    end

    context "positive" do
      it "returns the raw message headers and body" do
        get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/raw/#{msg.key}",
            headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["message_id_header"]).to eq("<test123@example.com>")
        expect(body["in_reply_to"]).to eq("<parent@example.com>")
        expect(body["body_plain"]).to eq("Raw body")
        expect(body["body_html"]).to eq("<p>Raw body</p>")
      end
    end

    context "negative" do
      it "returns 404 for nonexistent message" do
        get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/raw/msg_nonexistent",
            headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
