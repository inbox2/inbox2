require "rails_helper"

RSpec.describe "Api::V1::Agencies", type: :request do
  let(:owner) { create(:user, username: "agencyowner") }
  let(:headers) { auth_headers(owner) }

  describe "POST /api/v1/agency (spec 13.2.7)" do
    it "creates an agency" do
      post "/api/v1/agency",
           params: { name: "Acme Agency", billing_email: "billing@acme.com" },
           headers: headers
      expect(response).to have_http_status(:created)
      body = response.parsed_body["agency"]
      expect(body["id"]).to start_with("agy_")
      expect(body["name"]).to eq("Acme Agency")
    end

    # discount_percent is a platform/reseller grant, not self-serviceable — a
    # client-supplied value must be ignored, not honored (defaults to 0).
    it "ignores a client-supplied discount_percent" do
      post "/api/v1/agency",
           params: { name: "Acme Agency", discount_percent: 100 },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["agency"]["discount_percent"]).to eq(0)
      expect(Agency.find_by(owner: owner).discount_percent).to eq(0)
    end

    it "ignores discount_percent on update" do
      Agency.create!(owner: owner, name: "Mine", discount_percent: 0)
      patch "/api/v1/agency", params: { discount_percent: 100 }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(Agency.find_by(owner: owner).discount_percent).to eq(0)
    end
  end

  describe "GET /api/v1/agency" do
    let!(:agency) { Agency.create!(owner: owner, name: "My Agency") }

    it "shows agency details" do
      get "/api/v1/agency", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["agency"]["name"]).to eq("My Agency")
    end
  end

  describe "PATCH /api/v1/agency" do
    let!(:agency) { Agency.create!(owner: owner, name: "Old Name") }

    it "updates agency" do
      patch "/api/v1/agency", params: { name: "New Name" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["agency"]["name"]).to eq("New Name")
    end
  end

  describe "POST /api/v1/agency/organizations" do
    let!(:agency) { Agency.create!(owner: owner, name: "My Agency") }
    let!(:org) { create(:organization, owner: owner, domain: "agency-org.com") }
    let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

    it "adds an organization to the agency" do
      post "/api/v1/agency/organizations",
           params: { org_id: org.key },
           headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.agency).to eq(agency)
    end

    # Re-parenting an org under an agency is owner-only — a non-owner member of
    # the org (even if they own the agency) can't pull it in.
    it "forbids attaching an org the user does not own" do
      stranger = create(:user, username: "agency_stranger")
      foreign_org = create(:organization, owner: stranger, domain: "not-mine.com")
      create(:membership, user: stranger, organization: foreign_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
      # The agency owner is only a plain member of that org.
      create(:membership, user: owner, organization: foreign_org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)

      post "/api/v1/agency/organizations",
           params: { org_id: foreign_org.key },
           headers: headers
      expect(response).to have_http_status(:forbidden)
      expect(foreign_org.reload.agency).to be_nil
    end
  end

  describe "DELETE /api/v1/agency/organizations/:org_id" do
    let!(:agency) { Agency.create!(owner: owner, name: "My Agency") }
    let!(:org) { create(:organization, owner: owner, domain: "remove-org.com", agency: agency) }

    it "removes an organization from the agency" do
      delete "/api/v1/agency/organizations/#{org.key}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.agency).to be_nil
    end
  end

  describe "GET /api/v1/agency/billing" do
    let!(:agency) { Agency.create!(owner: owner, name: "My Agency", discount_percent: 10) }
    let!(:org1) { create(:organization, owner: owner, domain: "agency1.com", agency: agency) }
    let!(:org2) { create(:organization, owner: owner, domain: "agency2.com", agency: agency) }

    it "returns consolidated billing summary" do
      get "/api/v1/agency/billing", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["total_organizations"]).to eq(2)
      expect(body["discount_percent"]).to eq(10)
      # 2 orgs * $19 = $38 = 3800 cents, 10% discount = 3420
      expect(body["monthly_cost_cents"]).to eq(3420)
    end
  end
end
