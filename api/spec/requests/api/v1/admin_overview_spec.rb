require "rails_helper"

RSpec.describe "Api::V1::Admin overview", type: :request do
  let(:owner) { create(:user, username: "adminowner") }
  let(:org) { create(:organization, owner: owner, domain: "adminstats.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/admin/overview" do
    context "positive" do
      it "returns inbound/outbound, spam, classification and backlog counts over the 7-day window" do
        conv = create(:conversation, organization: org, status: "open")
        create(:message, organization: org, conversation: conv, is_inbound: true)
        create(:message, organization: org, conversation: conv, is_inbound: false)
        create(:message, organization: org, conversation: conv, is_inbound: true, spam_action: "reject")

        get "/api/v1/orgs/#{org.key}/admin/overview", headers: headers
        expect(response).to have_http_status(:ok)
        o = response.parsed_body["overview"]

        expect(o["inbound"]["last7"]).to eq(2)
        expect(o["outbound"]["last7"]).to eq(1)
        expect(o["inbound"]["prev7"]).to eq(0)
        expect(o["inbound"]["series"].length).to eq(7)
        expect(o["spam"]["scanned_7d"]).to eq(1)
        expect(o["spam"]["blocked_7d"]).to eq(1)
        # one open conversation, not yet routed into a space
        expect(o["classification"]["classifiable"]).to eq(1)
        expect(o["classification"]["classified"]).to eq(0)
        expect(o["unrouted"]).to eq(1)
        expect(o["pool"]["volume"]).to eq(1)
      end

      it "excludes non-open conversations from the pool and backlog" do
        create(:conversation, organization: org, status: "open")
        create(:conversation, organization: org, status: "archived")
        create(:conversation, organization: org, status: "trash")

        get "/api/v1/orgs/#{org.key}/admin/overview", headers: headers
        o = response.parsed_body["overview"]
        # only the open conversation counts toward the live inbox pool
        expect(o["pool"]["volume"]).to eq(1)
        expect(o["unrouted"]).to eq(1)
        expect(o["classification"]["classifiable"]).to eq(1)
      end

      it "compares this week against last week for the inbound delta window" do
        conv = create(:conversation, organization: org, status: "open")
        create(:message, organization: org, conversation: conv, is_inbound: true, created_at: 9.days.ago)

        get "/api/v1/orgs/#{org.key}/admin/overview", headers: headers
        o = response.parsed_body["overview"]
        expect(o["inbound"]["last7"]).to eq(0)
        expect(o["inbound"]["prev7"]).to eq(1)
      end

      it "counts a classified conversation toward coverage and out of the backlog" do
        Space.ensure_default_spaces(org)
        sales = org.spaces.find_by!(slug: "sales")
        create(:conversation, organization: org, status: "open", space: sales)

        get "/api/v1/orgs/#{org.key}/admin/overview", headers: headers
        o = response.parsed_body["overview"]
        expect(o["classification"]["classified"]).to eq(1)
        expect(o["unrouted"]).to eq(0)
      end
    end

    context "negative" do
      it "404s for a non-member" do
        outsider = create(:user, username: "adminoutsider")
        get "/api/v1/orgs/#{org.key}/admin/overview", headers: auth_headers(outsider)
        expect(response).to have_http_status(:not_found)
      end

      it "401s without auth" do
        get "/api/v1/orgs/#{org.key}/admin/overview"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
