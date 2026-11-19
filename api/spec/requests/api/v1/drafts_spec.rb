require "rails_helper"

RSpec.describe "Api::V1::Drafts", type: :request do
  # E1 mapping: spec 8.1.5, A7.4 — Drafts
  let(:owner) { create(:user, username: "draftowner") }
  let(:org) { create(:organization, owner: owner, domain: "drafts.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let!(:sender_box) { create(:mailbox, membership: membership, domain: org.default_domain, local_part: "me") }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/drafts" do
    it "lists draft messages" do
      conv = create(:conversation, organization: org)
      create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: membership.id)
      create(:message, conversation: conv, organization: org, is_draft: false)

      get "/api/v1/orgs/#{org.key}/drafts", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["drafts"].length).to eq(1)
    end

    it "hides a colleague's draft on their private imported thread, and won't delete it either" do
      mate = create(:user, username: "draftmate")
      mate_m = create(:membership, user: mate, organization: org, role: "member", status: "active")
      hidden = create(:conversation, organization: org, private: true, owner_membership_id: mate_m.id)
      secret = create(:message, conversation: hidden, organization: org, is_draft: true, subject: "Mate's private draft")

      get "/api/v1/orgs/#{org.key}/drafts", headers: headers
      expect(response.parsed_body["drafts"].map { |d| d["subject"] }).not_to include("Mate's private draft")

      delete "/api/v1/orgs/#{org.key}/drafts/#{secret.key}", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(Message.exists?(secret.id)).to be(true)
    end
  end

  describe "POST /api/v1/orgs/:org_id/drafts" do
    it "creates a new draft" do
      post "/api/v1/orgs/#{org.key}/drafts",
           params: { from_address: "me@drafts.com", subject: "Draft subject", body_plain: "Draft body" },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["draft"]["is_draft"]).to eq(true)
    end

    it "persists CC and BCC recipients" do
      post "/api/v1/orgs/#{org.key}/drafts",
           params: { from_address: "me@drafts.com", to_address: "you@x.com",
                     cc_address: "cc@x.com", bcc_address: "blind@x.com", subject: "S" },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["draft"]["cc_address"]).to eq("cc@x.com")
      expect(response.parsed_body["draft"]["bcc_address"]).to eq("blind@x.com")
    end
  end

  describe "POST /api/v1/orgs/:org_id/drafts with a client Message-ID" do
    let(:mid) { "<drf_1@drafts.com>" }

    it "upserts: a newer version replaces the draft whole, clearing what it omits" do
      post "/api/v1/orgs/#{org.key}/drafts",
           params: { message_id_header: mid, from_address: "me@drafts.com", cc_address: "cc@x.com", body_plain: "v1" },
           headers: headers
      expect(response).to have_http_status(:created)
      key = response.parsed_body["draft"]["id"]

      post "/api/v1/orgs/#{org.key}/drafts",
           params: { message_id_header: mid, from_address: "me@drafts.com", body_plain: "v2" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["draft"]["id"]).to eq(key)
      draft = Message.find_by!(key: key)
      expect([draft.body_plain, draft.cc_address]).to eq(["v2", nil])
      expect(org.messages.where(message_id_header: mid).count).to eq(1)
    end

    it "refuses to overwrite a message that was already sent" do
      conv = create(:conversation, organization: org)
      create(:message, conversation: conv, organization: org, is_draft: false, message_id_header: mid)
      post "/api/v1/orgs/#{org.key}/drafts",
           params: { message_id_header: mid, from_address: "me@drafts.com", body_plain: "v3" }, headers: headers
      expect(response).to have_http_status(:conflict)
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/drafts/:id" do
    let!(:conv) { create(:conversation, organization: org) }
    let!(:draft) { create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: membership.id, body_plain: "Old") }

    it "updates a draft" do
      patch "/api/v1/orgs/#{org.key}/drafts/#{draft.key}",
            params: { body_plain: "Updated draft" },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(draft.reload.body_plain).to eq("Updated draft")
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/drafts/:id with replace" do
    it "clears a field sent blank, and only with replace" do
      conv = create(:conversation, organization: org)
      draft = create(:message, organization: org, conversation: conv, is_draft: true,
                               owner_membership_id: membership.id, cc_address: "c@x.test")
      patch "/api/v1/orgs/#{org.key}/drafts/#{draft.key}", params: { cc_address: "" }, headers: headers
      expect(draft.reload.cc_address).to eq("c@x.test")
      patch "/api/v1/orgs/#{org.key}/drafts/#{draft.key}", params: { cc_address: "", replace: true }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(draft.reload.cc_address).to eq("")
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/drafts/:id" do
    let!(:conv) { create(:conversation, organization: org) }
    let!(:draft) { create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: membership.id) }

    it "deletes a draft" do
      expect {
        delete "/api/v1/orgs/#{org.key}/drafts/#{draft.key}", headers: headers
      }.to change(Message, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "removes the conversation when the deleted draft was its only message" do
      delete "/api/v1/orgs/#{org.key}/drafts/#{draft.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Conversation.exists?(conv.id)).to eq(false)
    end

    it "keeps the conversation when other messages remain" do
      create(:message, conversation: conv, organization: org, is_draft: false)
      delete "/api/v1/orgs/#{org.key}/drafts/#{draft.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Conversation.exists?(conv.id)).to eq(true)
    end
  end

  describe "drafts — negative paths" do
    it "returns 404 when creating against an unknown conversation" do
      post "/api/v1/orgs/#{org.key}/drafts",
           params: { conversation_id: "conv_missing", body_plain: "x" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when updating a non-draft message" do
      conv = create(:conversation, organization: org)
      sent = create(:message, conversation: conv, organization: org, is_draft: false)
      patch "/api/v1/orgs/#{org.key}/drafts/#{sent.key}", params: { body_plain: "x" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 when deleting an unknown draft" do
      delete "/api/v1/orgs/#{org.key}/drafts/msg_missing", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      get "/api/v1/orgs/#{org.key}/drafts"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "drafts are their author's alone (2026-10-24)" do
    let(:mate) { create(:user, username: "draftcolleague") }
    let!(:mate_m) { create(:membership, user: mate, organization: org, role: "admin", status: "active") }

    it "keeps a colleague's reply draft out of the drafts list and the thread" do
      conv = create(:conversation, organization: org, domain: org.default_domain, to_address: "support@drafts.com")
      create(:message, conversation: conv, organization: org, is_draft: false)
      theirs = create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: mate_m.id)

      get "/api/v1/orgs/#{org.key}/drafts", headers: headers
      expect(response.parsed_body["drafts"]).to be_empty

      get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}", headers: headers
      keys = response.parsed_body.dig("conversation", "messages").map { |m| m["id"] }
      expect(keys).not_to include(theirs.key)

      patch "/api/v1/orgs/#{org.key}/drafts/#{theirs.key}", params: { subject: "x" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "keeps a colleague's draft out of the Drafts folder and its attachment out of reach" do
      conv = create(:conversation, organization: org, domain: org.default_domain, to_address: "support@drafts.com")
      create(:message, conversation: conv, organization: org, is_draft: false)
      theirs = create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: mate_m.id)
      att = create(:attachment, message: theirs, storage_key: "k")

      get "/api/v1/orgs/#{org.key}/conversations", params: { is_draft: "true", status: "open" }, headers: headers
      expect(response.parsed_body["conversations"]).to be_empty

      get "/api/v1/orgs/#{org.key}/attachments/#{att.key}", headers: headers
      expect(response).to have_http_status(:not_found)

      post "/api/v1/orgs/#{org.key}/attachments",
           params: { message_id: theirs.key, file: Rack::Test::UploadedFile.new(StringIO.new("x"), "text/plain", original_filename: "x.txt") },
           headers: headers
      expect(response).to have_http_status(:not_found)
      expect(theirs.attachments.count).to eq(1)
    end

    it "keeps the thread private when the first send fails, and again after an undone send" do
      membership.update!(send_as_addresses: ["support@drafts.com"])
      post "/api/v1/orgs/#{org.key}/drafts", params: { from_address: "support@drafts.com", subject: "Plan" }, headers: headers
      conv = Message.find_by!(key: response.parsed_body.dig("draft", "id")).conversation

      # No From: the message fails validation, the thread must not go shared.
      post "/api/v1/orgs/#{org.key}/messages", params: { conversation_id: conv.key, to_address: "x@example.com", body_plain: "hi" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(conv.reload.private).to be(true)

      post "/api/v1/orgs/#{org.key}/messages",
           params: { conversation_id: conv.key, from_address: "support@drafts.com", to_address: "x@example.com", body_plain: "hi" }, headers: headers
      expect(conv.reload.private).to be(false)
      sent = response.parsed_body.dig("message", "id")

      post "/api/v1/orgs/#{org.key}/messages/#{sent}/cancel-send", headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload).to have_attributes(private: true, owner_membership_id: membership.id)
      expect(org.conversations.visible_to(mate_m)).not_to include(conv)
    end

    it "re-stamps the personal owner when the draft's From switches" do
      membership.update!(send_as_addresses: ["support@drafts.com"])
      post "/api/v1/orgs/#{org.key}/drafts", params: { from_address: "support@drafts.com" }, headers: headers
      draft = Message.find_by!(key: response.parsed_body.dig("draft", "id"))
      expect(draft.conversation.personal_membership_id).to be_nil

      patch "/api/v1/orgs/#{org.key}/drafts/#{draft.key}", params: { from_address: "me@drafts.com" }, headers: headers
      expect(draft.conversation.reload.personal_membership_id).to eq(membership.id)
      patch "/api/v1/orgs/#{org.key}/drafts/#{draft.key}", params: { from_address: "support@drafts.com" }, headers: headers
      expect(draft.conversation.reload.personal_membership_id).to be_nil
    end

    it "leaves a thread shared on undo when a colleague has a draft in it" do
      membership.update!(send_as_addresses: ["support@drafts.com"])
      conv = create(:conversation, organization: org, domain: org.default_domain, from_address: "support@drafts.com", to_address: "x@example.com")
      sent = create(:message, conversation: conv, organization: org, is_draft: false, is_inbound: false,
                    from_address: "support@drafts.com", sender_membership_id: membership.id)
      create(:message, conversation: conv, organization: org, is_draft: true, owner_membership_id: mate_m.id)

      post "/api/v1/orgs/#{org.key}/messages/#{sent.key}/cancel-send", headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload.private).to be(false)
      expect(org.conversations.visible_to(mate_m)).to include(conv)
    end

    it "files a new compose draft on a thread private to its author until it is scheduled" do
      membership.update!(send_as_addresses: ["support@drafts.com"]) # a shared address, not a personal mailbox
      post "/api/v1/orgs/#{org.key}/drafts", params: { from_address: "support@drafts.com", subject: "Secret plan" }, headers: headers
      draft = Message.find_by!(key: response.parsed_body.dig("draft", "id"))
      conv = draft.conversation
      expect(conv).to have_attributes(private: true, owner_membership_id: membership.id)
      expect(draft.owner_membership_id).to eq(membership.id)
      expect(org.conversations.visible_to(mate_m)).not_to include(conv)
      expect(org.conversations.visible_to(membership)).to include(conv)

      draft.update!(to_address: "x@example.com")
      post "/api/v1/orgs/#{org.key}/messages/#{draft.key}/schedule", params: { send_at: 1.hour.from_now.iso8601 }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(conv.reload).to have_attributes(private: false, owner_membership_id: nil)
      expect(draft.reload.owner_membership_id).to be_nil
      expect(org.conversations.visible_to(mate_m)).to include(conv)
    end
  end
end
