require "rails_helper"

RSpec.describe "Api::V1::Billing", type: :request do
  let(:user) { create(:user, username: "billuser") }
  let(:org) { create(:organization, owner: user) }
  let!(:membership) { create(:membership, user: user, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(user) }

  describe "GET /api/v1/plans" do
    it "lists the three tiers" do
      get "/api/v1/plans"
      expect(response).to have_http_status(:ok)
      names = response.parsed_body["plans"].map { |p| p["name"] }
      expect(names).to include("Free", "Startup", "Serial Entrepreneur")
      response.parsed_body["plans"].each { |p| expect(p["id"]).to start_with("plan_") }
    end
  end

  describe "GET /api/v1/orgs/:org_id/billing" do
    it "returns Free + usage for a fresh org" do
      get "/api/v1/orgs/#{org.key}/billing", headers: headers
      expect(response).to have_http_status(:ok)
      b = response.parsed_body
      expect(b["plan"]["name"]).to eq("Free")
      expect(b["status"]).to eq("free")
      expect(b["domains_used"]).to eq(1)
      expect(b["domain_limit_reached"]).to be(true)
      expect(b["collaborator_limit_reached"]).to be(true) # Free = 0 collaborators
      expect(b["locked_domains"]).to eq(0)
    end

    it "404s for an org the user is not a member of" do
      other = create(:organization)
      get "/api/v1/orgs/#{other.key}/billing", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /billing/subscribe — upgrade (mocked Stripe)" do
    it "upgrades to Startup and records mock Stripe ids" do
      post "/api/v1/orgs/#{org.key}/billing/subscribe", params: { plan_id: Plan.paid.key }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["subscription"]["plan"]["name"]).to eq("Startup")
      sub = org.reload.subscription
      expect(sub.stripe_customer_id).to start_with("cus_mock_")
      expect(sub.stripe_subscription_id).to start_with("sub_mock_")
      expect(sub.status).to eq("active")
    end

    it "403s a non-admin member" do
      member = create(:user)
      create(:membership, user: member, organization: org, role: "member", status: "active")
      post "/api/v1/orgs/#{org.key}/billing/subscribe", params: { plan_id: Plan.paid.key }, headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /billing/subscribe — downgrade with lock" do
    before do
      create(:subscription, organization: org, plan: Plan.max)
      create(:domain, organization: org, name: "second.test") # 2 domains total
      create(:membership, organization: org, user: create(:user), role: "member", status: "active") # 1 collaborator
    end

    it "422s without acknowledge and reports the impact" do
      post "/api/v1/orgs/#{org.key}/billing/subscribe", params: { plan_id: Plan.free.key }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      body = response.parsed_body
      expect(body["code"]).to eq("downgrade_requires_acknowledgement")
      expect(body["impact"]["domains_over"]).to eq(1)
      expect(body["impact"]["collaborators_over"]).to eq(1)
    end

    it "downgrades with acknowledge — locks the newest domain + disables the excess collaborator" do
      post "/api/v1/orgs/#{org.key}/billing/subscribe", params: { plan_id: Plan.free.key, acknowledge: true }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.effective_plan.name).to eq("Free")
      expect(org.domains.where.not(locked_at: nil).pluck(:name)).to eq(["second.test"])
      expect(org.memberships.where(status: Membership::STATUS_DISABLED).count).to eq(1)
    end

    it "re-enables the locked domain + collaborator when upgrading back" do
      post "/api/v1/orgs/#{org.key}/billing/subscribe", params: { plan_id: Plan.free.key, acknowledge: true }, headers: headers
      expect(org.reload.memberships.where(status: Membership::STATUS_DISABLED).count).to eq(1)

      post "/api/v1/orgs/#{org.key}/billing/subscribe", params: { plan_id: Plan.max.key }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.domains.where.not(locked_at: nil)).to be_empty
      expect(org.memberships.where(status: Membership::STATUS_DISABLED)).to be_empty
    end
  end

  describe "GET /billing/invoices" do
    it "returns the empty stub" do
      get "/api/v1/orgs/#{org.key}/billing/invoices", headers: headers
      expect(response.parsed_body["invoices"]).to eq([])
    end
  end
end
