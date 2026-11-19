require "rails_helper"

RSpec.describe "Api::V1::Assignment", type: :request do
  let(:owner) { create(:user, username: "assignowner") }
  let(:org) { create(:organization, owner: owner, domain: "assign.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }
  let!(:conv) { create(:conversation, organization: org) }

  let(:member1) { create(:user, username: "assignee1") }
  let!(:member1_membership) { create(:membership, user: member1, organization: org, role: "member", status: "active") }
  let(:member2) { create(:user, username: "assignee2") }
  let!(:member2_membership) { create(:membership, user: member2, organization: org, role: "member", status: "active") }

  # --- Spec 5.2.1, A8.1 — Set assignees ---
  describe "PUT /api/v1/orgs/:org_id/conversations/:id/assignees" do
    context "positive" do
      it "assigns members to a conversation" do
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/assignees",
            params: { member_ids: [member1_membership.key, member2_membership.key] },
            headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["assignees"].length).to eq(2)
        expect(body["assignees"].map { |a| a["id"] }).to include(member1_membership.key, member2_membership.key)
      end

      it "replaces existing assignees" do
        conv.assignees << member1_membership
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/assignees",
            params: { member_ids: [member2_membership.key] },
            headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["assignees"].length).to eq(1)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a conversation in another org" do
        other_user = create(:user, username: "assigniso")
        other_org = create(:organization, owner: other_user, domain: "assigniso.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        other_conv = create(:conversation, organization: other_org)

        put "/api/v1/orgs/#{org.key}/conversations/#{other_conv.key}/assignees",
            params: { member_ids: [member1_membership.key] },
            headers: headers
        expect(response).to have_http_status(:not_found)
      end

      it "ignores members from another org" do
        other_user = create(:user, username: "foreignmember")
        other_org = create(:organization, owner: other_user, domain: "foreign.com")
        foreign_membership = create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/assignees",
            params: { member_ids: [foreign_membership.key] },
            headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["assignees"]).to eq([])
      end
    end
  end

  # --- Spec 5.2.3, A8.2 — Remove assignee ---
  describe "DELETE /api/v1/orgs/:org_id/conversations/:id/assignees/:member_id" do
    before { conv.assignees << member1_membership }

    context "positive" do
      it "removes an assignee" do
        expect {
          delete "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/assignees/#{member1_membership.key}",
                 headers: headers
        }.to change(ConversationAssignee, :count).by(-1)
        expect(response).to have_http_status(:no_content)
      end
    end
  end

  # --- Spec 5.3.1, A8.3 — Grant access ---
  describe "PUT /api/v1/orgs/:org_id/conversations/:id/access" do
    context "positive" do
      it "grants access to members" do
        put "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/access",
            params: { member_ids: [member1_membership.key] },
            headers: headers
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["access"].length).to eq(1)
        expect(body["access"].first["id"]).to eq(member1_membership.key)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for a conversation in another org" do
        other_user = create(:user, username: "accessiso")
        other_org = create(:organization, owner: other_user, domain: "accessiso.com")
        create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")
        other_conv = create(:conversation, organization: other_org)

        put "/api/v1/orgs/#{org.key}/conversations/#{other_conv.key}/access",
            params: { member_ids: [member1_membership.key] },
            headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # --- Spec 5.3.3, A8.4 — Revoke access ---
  describe "DELETE /api/v1/orgs/:org_id/conversations/:id/access/:member_id" do
    before { conv.accessible_members << member1_membership }

    context "positive" do
      it "revokes access" do
        expect {
          delete "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/access/#{member1_membership.key}",
                 headers: headers
        }.to change(ConversationAccess, :count).by(-1)
        expect(response).to have_http_status(:no_content)
      end
    end
  end
end
