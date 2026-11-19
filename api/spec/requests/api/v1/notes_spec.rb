require "rails_helper"

RSpec.describe "Api::V1::Notes", type: :request do
  let(:owner) { create(:user, username: "noteowner") }
  let(:org) { create(:organization, owner: owner, domain: "notes.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }
  let!(:conv) { create(:conversation, organization: org) }

  # --- Spec 9.1.1, A12.1 — Add note ---
  describe "POST /api/v1/orgs/:org_id/conversations/:id/notes" do
    context "positive" do
      it "creates a note on a conversation" do
        expect {
          post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes",
               params: { body: "Internal note here" },
               headers: headers
        }.to change(Note, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["note"]["id"]).to start_with("note_")
        expect(body["note"]["body"]).to eq("Internal note here")
        expect(body["note"]["author"]["id"]).to eq(owner_membership.key)
        expect(body["note"]).not_to have_key("conversation_id")
        expect(body["note"]).not_to have_key("organization_id")
        expect(body["note"]).not_to have_key("membership_id")
      end

      it "creates a threaded reply (spec 9.1.7)" do
        parent = create(:note, conversation: conv, organization: org, membership: owner_membership, body: "Parent note")

        post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes",
             params: { body: "Reply to parent", parent_note_id: parent.key },
             headers: headers
        expect(response).to have_http_status(:created)
        expect(response.parsed_body["note"]["parent_note_id"]).to eq(parent.key)
      end
    end

    context "negative — empty body" do
      it "rejects note without body" do
        post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes",
             params: { body: "" },
             headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a conversation in another org" do
        other_user = create(:user, username: "noteiso")
        other_org = create(:organization, owner: other_user, domain: "noteiso.com")
        create(:membership, user: other_user, organization: other_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
        other_conv = create(:conversation, organization: other_org)

        post "/api/v1/orgs/#{org.key}/conversations/#{other_conv.key}/notes",
             params: { body: "Should fail" },
             headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "negative — unauthorized" do
      it "rejects unauthenticated request" do
        post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes",
             params: { body: "Unauthorized" }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  # --- Spec 9.1.6, A12.2 — Edit/delete notes ---
  describe "PATCH /api/v1/orgs/:org_id/conversations/:id/notes/:note_id" do
    let!(:note) { create(:note, conversation: conv, organization: org, membership: owner_membership, body: "Original") }

    it "updates own note" do
      patch "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes/#{note.key}",
            params: { body: "Updated body" },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["note"]["body"]).to eq("Updated body")
    end

    it "forbids editing another member's note" do
      other = create(:user, username: "noteanother")
      other_mbr = create(:membership, user: other, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      other_note = create(:note, conversation: conv, organization: org, membership: other_mbr, body: "Other's note")

      patch "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes/#{other_note.key}",
            params: { body: "Hijack" },
            headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/conversations/:id/notes/:note_id" do
    let!(:note) { create(:note, conversation: conv, organization: org, membership: owner_membership, body: "To delete") }

    it "deletes own note" do
      expect {
        delete "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes/#{note.key}", headers: headers
      }.to change(Note, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  # --- Spec 9.1.7 — Reactions ---
  describe "POST /api/v1/orgs/:org_id/conversations/:id/notes/:note_id/reactions" do
    let!(:note) { create(:note, conversation: conv, organization: org, membership: owner_membership, body: "React to me") }

    it "adds a reaction" do
      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes/#{note.key}/reactions",
           params: { emoji: "thumbsup" },
           headers: headers
      expect(response).to have_http_status(:ok)
      reactions = response.parsed_body["note"]["reactions"]
      expect(reactions.first["emoji"]).to eq("thumbsup")
      expect(reactions.first["count"]).to eq(1)
    end

    it "rejects duplicate reaction" do
      note.reactions.create!(membership: owner_membership, emoji: "thumbsup")

      post "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes/#{note.key}/reactions",
           params: { emoji: "thumbsup" },
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/conversations/:id/notes/:note_id/reactions" do
    let!(:note) { create(:note, conversation: conv, organization: org, membership: owner_membership, body: "Unreact me") }

    it "removes a reaction" do
      note.reactions.create!(membership: owner_membership, emoji: "thumbsup")

      delete "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/notes/#{note.key}/reactions",
             params: { emoji: "thumbsup" },
             headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["note"]["reactions"]).to be_empty
    end
  end
end
