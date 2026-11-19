require "rails_helper"

RSpec.describe "Api::V1::Organizations", type: :request do
  let(:user) { create(:user) }
  let(:headers) { auth_headers(user) }

  # Spec 2.3.1, A3.1 — Create organization
  describe "POST /api/v1/orgs" do
    context "positive" do
      it "creates an organization and owner membership" do
        post "/api/v1/orgs", params: { domain: "newdomain.com", name: "New Domain" }, headers: headers
        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["organization"]["domain"]).to eq("newdomain.com")
        expect(body["organization"]["id"]).to start_with("org_")
        # E5: no internal numeric ID
        expect(body["organization"]).not_to have_key("internal_id")
        # Owner membership auto-created
        expect(Membership.find_by(user: user, organization: Organization.last, role: "owner")).to be_present
      end

      it "seeds the system priority tags that back the Eisenhower matrix" do
        post "/api/v1/orgs", params: { domain: "newdomain.com", name: "New Domain" }, headers: headers
        expect(response).to have_http_status(:created)
        org = Organization.last
        expect(org.tags.system_tags.pluck(:name)).to contain_exactly("Urgent", "Important", "Later")
      end

      it "seeds the canonical Spaces (incl. the Triage holding pen) so MX mail classifies from birth" do
        post "/api/v1/orgs", params: { domain: "newdomain.com", name: "New Domain" }, headers: headers
        expect(response).to have_http_status(:created)
        org = Organization.last
        expect(org.spaces.pluck(:slug)).to contain_exactly("support", "sales", "marketing", "finance", "operations", "triage")
        # The holding pen exists and is excluded from auto-classification.
        expect(org.spaces.find_by(slug: "triage").classify).to be(false)
      end
    end

    context "negative" do
      it "rejects a domain already in use" do
        create(:organization, domain: "taken.com", owner: user)
        post "/api/v1/orgs", params: { domain: "taken.com", name: "Duplicate" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects missing domain" do
        post "/api/v1/orgs", params: { name: "No Domain" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # Spec A3.2 — Read organization
  describe "GET /api/v1/orgs/:org_id" do
    context "positive" do
      it "returns the organization" do
        org = create(:organization, owner: user)
        create(:membership, user: user, organization: org, status: "active")

        get "/api/v1/orgs/#{org.key}", headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["organization"]["domain"]).to eq(org.default_domain.name)
      end
    end

    context "negative — tenant isolation (E3)" do
      it "returns 404 for an organization the user has no membership in" do
        other_user = create(:user, username: "other")
        other_org = create(:organization, owner: other_user, domain: "other.com")
        create(:membership, user: other_user, organization: other_org, status: "active")

        get "/api/v1/orgs/#{other_org.key}", headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # Spec A3.3 — Update organization
  describe "PATCH /api/v1/orgs/:org_id" do
    let(:org) { create(:organization, owner: user) }
    let!(:membership) { create(:membership, user: user, organization: org, role: "owner", status: "active") }

    context "positive" do
      it "updates org settings" do
        patch "/api/v1/orgs/#{org.key}", params: { name: "Updated" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["organization"]["name"]).to eq("Updated")
      end
    end

    context "negative — role check" do
      it "forbids non-admin members from updating" do
        member = create(:user, username: "member1")
        create(:membership, user: member, organization: org, role: "member", status: "active")
        member_headers = auth_headers(member)

        patch "/api/v1/orgs/#{org.key}", params: { name: "Hacked" }, headers: member_headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # Spec 2.4.1, A3.12 — Onboarding checklist (OrganizationOnboardingSerializer)
  describe "GET /api/v1/orgs/:org_id/onboarding" do
    let(:onboard_org) { create(:organization, owner: user, domain: "onboard.com").tap { |o| o.default_domain.update!(status: "pending_dns") } }
    let!(:onboard_membership) do
      create(:membership, user: user, organization: onboard_org, role: "owner", status: "active")
    end

    it "returns the checklist, completed count and total" do
      get "/api/v1/orgs/#{onboard_org.key}/onboarding", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["checklist"].keys).to match_array(
        %w[domain_added dns_verified members_invited first_rule_created test_email_received]
      )
      # Fresh org: only the domain step is done.
      expect(body["checklist"]["domain_added"]).to be(true)
      expect(body["checklist"]["dns_verified"]).to be(false)
      expect(body["completed"]).to eq(1)
      expect(body["total"]).to eq(5)
    end

    it "marks dns_verified once the domain leaves pending_dns" do
      onboard_org.default_domain.update!(status: "verified")
      get "/api/v1/orgs/#{onboard_org.key}/onboarding", headers: headers
      body = response.parsed_body
      expect(body["checklist"]["dns_verified"]).to be(true)
      expect(body["completed"]).to eq(2)
    end
  end
end
