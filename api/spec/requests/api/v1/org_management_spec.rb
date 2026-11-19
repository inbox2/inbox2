require "rails_helper"

RSpec.describe "Api::V1::OrgManagement", type: :request do
  # E1 mapping: spec 2.2.5-2.2.7/4.3.4/11.3.4, A2.4/A3.4/A3.8-A3.10/A6.9 — Org management
  let(:owner) { create(:user, username: "orgmgmt") }
  let(:org) { create(:organization, owner: owner, domain: "mgmt.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/account/organizations" do
    it "lists accessible organizations" do
      get "/api/v1/account/organizations", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["organizations"].length).to eq(1)
    end
  end

  describe "POST /api/v1/orgs/:org_id/transfer-ownership" do
    it "transfers ownership to another member" do
      new_owner = create(:user, username: "newowner")
      new_membership = create(:membership, user: new_owner, organization: org, role: "admin", status: "active")

      post "/api/v1/orgs/#{org.key}/transfer-ownership",
           params: { member_id: new_membership.key }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.owner).to eq(new_owner)
    end
  end

  describe "GET /api/v1/orgs/:org_id/conversations/:id/activity" do
    it "returns activity events" do
      conv = create(:conversation, organization: org)
      ActivityEvent.log(conversation: conv, action: "created")

      get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/activity", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["activity"].length).to eq(1)
    end

    it "returns 404 for activity on a colleague's private imported thread" do
      mate_m = create(:membership, user: create(:user, username: "actmate"), organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      hidden = create(:conversation, organization: org, private: true, owner_membership_id: mate_m.id)

      get "/api/v1/orgs/#{org.key}/conversations/#{hidden.key}/activity", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "org management — negative paths" do
    it "forbids a non-owner from transferring ownership" do
      admin = create(:user, username: "mgmtadmin")
      create(:membership, user: admin, organization: org, role: "admin", status: "active")
      target = create(:membership, user: create(:user, username: "mgmttarget"),
                                    organization: org, role: "admin", status: "active")

      post "/api/v1/orgs/#{org.key}/transfer-ownership",
           params: { member_id: target.key }, headers: auth_headers(admin)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 transferring to an unknown member" do
      post "/api/v1/orgs/#{org.key}/transfer-ownership",
           params: { member_id: "mbr_missing" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for activity on an unknown conversation" do
      get "/api/v1/orgs/#{org.key}/conversations/conv_missing/activity", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      get "/api/v1/account/organizations"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
