require "rails_helper"

RSpec.describe "Api::V1::Saas::Organizations", :saas, type: :request do
  let(:credential) { create(:admin_credential) }
  let(:headers) { saas_headers(credential) }

  def json = JSON.parse(response.body)

  describe "GET /index" do
    it "lists all orgs (cross-tenant) and filters by q" do
      create(:organization, name: "Acme Corp", domain: "acme.test")
      create(:organization, name: "Globex", domain: "globex.test")

      get "/api/v1/saas/organizations", params: { q: "acme" }, headers: headers

      expect(response).to have_http_status(:ok)
      domains = json["organizations"].map { |o| o["domain"] }
      expect(domains).to include("acme.test")
      expect(domains).not_to include("globex.test")
      expect(json["meta"]).to include("total", "page", "per_page")
    end
  end

  describe "GET /show" do
    it "returns any org regardless of membership (E3 bypass)" do
      org = create(:organization)
      get "/api/v1/saas/organizations/#{org.key}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json["organization"]["id"]).to eq(org.key)
      expect(json["organization"]["plan"]).to eq(Plan::NAME_FREE)
    end

    it "404s for an unknown org" do
      get "/api/v1/saas/organizations/org_missing", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /create" do
    it "creates an org owned by an existing user" do
      owner = create(:user)
      expect {
        post "/api/v1/saas/organizations",
          params: { owner_id: owner.key, name: "New Co", domain: "newco.test" }, headers: headers
      }.to change(Organization, :count).by(1)
      expect(response).to have_http_status(:created)
      org = Organization.last
      expect(org.owner).to eq(owner)
      # Same birth as a self-service signup (Organization.provision!): the SaaS
      # path used to skip these and such orgs limped along on lazy ensure_* calls.
      expect(org.memberships.active.owners.where(user: owner)).to exist
      expect(org.subscription&.plan).to eq(Plan.free)
      expect(org.tags.where(name: Tag::SYSTEM_TAGS.map { |t| t[:name] }).count).to eq(Tag::SYSTEM_TAGS.size)
      expect(org.spaces).to exist
    end

    it "422s without a valid owner" do
      post "/api/v1/saas/organizations",
        params: { owner_id: "usr_nope", name: "X", domain: "x.test" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /update" do
    it "updates allow-listed fields" do
      org = create(:organization)
      patch "/api/v1/saas/organizations/#{org.key}",
        params: { name: "Renamed", data_retention_days: 90 }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.name).to eq("Renamed")
      expect(org.data_retention_days).to eq(90)
    end
  end

  describe "suspend / unsuspend" do
    it "suspends and unsuspends, recording an audit row" do
      org = create(:organization)

      expect {
        post "/api/v1/saas/organizations/#{org.key}/suspend", params: { reason: "abuse" }, headers: headers
      }.to change(SaasAuditLog, :count).by(1)
      expect(org.reload).to be_suspended
      expect(org.suspended_reason).to eq("abuse")

      post "/api/v1/saas/organizations/#{org.key}/unsuspend", headers: headers
      expect(org.reload).not_to be_suspended
    end
  end

  describe "DELETE /wipe" do
    it "hard-wipes the org and its dependents and logs a snapshot" do
      org = create(:organization)
      domain_name = org.default_domain.name
      create(:membership, organization: org)

      expect {
        delete "/api/v1/saas/organizations/#{org.key}/wipe", headers: headers
      }.to change(Organization, :count).by(-1).and change(Membership, :count).by(-1)

      expect(response).to have_http_status(:no_content)
      log = SaasAuditLog.where(action: SaasAuditLog::ACTION_ORG_WIPE).last
      expect(log.metadata["domain"]).to eq(domain_name)
    end
  end

  describe "GET /usage" do
    it "returns counts and storage bytes" do
      org = create(:organization)
      m = create(:membership, organization: org)
      create(:mailbox, membership: m, domain: org.default_domain, local_part: "u")

      get "/api/v1/saas/organizations/#{org.key}/usage", headers: headers

      expect(response).to have_http_status(:ok)
      usage = json["usage"]
      expect(usage["mailboxes"]).to eq(1)
      expect(usage).to include("conversations", "messages", "attachments", "storage_bytes")
    end
  end

  describe "POST /plan" do
    let!(:paid) { Plan.max }

    it "sets a per-org override that flips the effective plan, then clears it" do
      org = create(:organization)
      expect(org.effective_plan.name).to eq(Plan::NAME_FREE)

      post "/api/v1/saas/organizations/#{org.key}/plan", params: { plan: Plan::NAME_SERIAL }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.effective_plan.name).to eq(Plan::NAME_SERIAL)

      post "/api/v1/saas/organizations/#{org.key}/plan", params: { plan: "inherit" }, headers: headers
      expect(org.reload.plan).to be_nil
      expect(org.effective_plan.name).to eq(Plan::NAME_FREE)
    end

    it "422s for an unknown plan" do
      org = create(:organization)
      post "/api/v1/saas/organizations/#{org.key}/plan", params: { plan: "Platinum" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /mailbox_limit" do
    it "accepts a preset" do
      org = create(:organization)
      post "/api/v1/saas/organizations/#{org.key}/mailbox_limit", params: { preset: "team" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.reload.mailbox_limit).to eq(5)
    end

    it "accepts an integer and clears with null" do
      org = create(:organization)
      post "/api/v1/saas/organizations/#{org.key}/mailbox_limit", params: { mailbox_limit: 3 }, headers: headers
      expect(org.reload.mailbox_limit).to eq(3)

      post "/api/v1/saas/organizations/#{org.key}/mailbox_limit", params: { mailbox_limit: nil }, headers: headers
      expect(org.reload.mailbox_limit).to be_nil
    end

    it "422s for an unknown preset" do
      org = create(:organization)
      post "/api/v1/saas/organizations/#{org.key}/mailbox_limit", params: { preset: "huge" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
