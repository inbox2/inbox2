require "rails_helper"

RSpec.describe "Api::V1::Integrations", type: :request do
  let(:owner) { create(:user, username: "intgowner") }
  let(:org) { create(:organization, owner: owner, domain: "integrations.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/integrations (spec 14.6)" do
    it "lists integrations" do
      Integration.create!(organization: org, name: "Slack Notifier", provider: Integration::PROVIDER_SLACK)
      get "/api/v1/orgs/#{org.key}/integrations", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["integrations"].length).to eq(1)
      expect(response.parsed_body["integrations"].first["id"]).to start_with("int_")
      expect(response.parsed_body["integrations"].first).not_to have_key("access_token_digest")
    end
  end

  describe "POST /api/v1/orgs/:org_id/integrations" do
    it "creates an integration" do
      post "/api/v1/orgs/#{org.key}/integrations",
           params: {
             name: "Slack Sales",
             provider: Integration::PROVIDER_SLACK,
             events: [Integration::EVENTS.first]
           },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["integration"]["provider"]).to eq(Integration::PROVIDER_SLACK)
    end

    it "rejects invalid provider" do
      post "/api/v1/orgs/#{org.key}/integrations",
           params: { name: "Bad", provider: "invalid_provider" },
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects invalid events" do
      post "/api/v1/orgs/#{org.key}/integrations",
           params: { name: "Bad Events", provider: Integration::PROVIDER_SLACK, events: ["bad.event"] },
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "forbids regular members" do
      member = create(:user, username: "intgmember")
      create(:membership, user: member, organization: org, role: Membership::ROLE_MEMBER, status: Membership::STATUS_ACTIVE)
      post "/api/v1/orgs/#{org.key}/integrations",
           params: { name: "Blocked", provider: Integration::PROVIDER_SLACK },
           headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/integrations/:id" do
    let!(:integration) { Integration.create!(organization: org, name: "Old", provider: Integration::PROVIDER_TEAMS) }

    it "updates integration" do
      patch "/api/v1/orgs/#{org.key}/integrations/#{integration.key}",
            params: { name: "Updated Name" },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["integration"]["name"]).to eq("Updated Name")
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/integrations/:id" do
    let!(:integration) { Integration.create!(organization: org, name: "To Delete", provider: Integration::PROVIDER_ZAPIER) }

    it "deletes integration" do
      expect {
        delete "/api/v1/orgs/#{org.key}/integrations/#{integration.key}", headers: headers
      }.to change(Integration, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "returns 404 for tenant isolation (E3)" do
      other_user = create(:user, username: "intgiso")
      other_org = create(:organization, owner: other_user, domain: "intgiso.com")
      create(:membership, user: other_user, organization: other_org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE)
      other_intg = Integration.create!(organization: other_org, name: "Other", provider: Integration::PROVIDER_SLACK)

      delete "/api/v1/orgs/#{org.key}/integrations/#{other_intg.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "config secret redaction" do
    let!(:integration) do
      Integration.create!(organization: org, name: "Slack", provider: Integration::PROVIDER_SLACK,
        config: { "webhook_url" => "https://hooks.slack.com/services/SECRET", "channel" => "#sales" })
    end

    it "masks secret-bearing config values on read but keeps non-secret keys" do
      get "/api/v1/orgs/#{org.key}/integrations/#{integration.key}", headers: headers
      cfg = response.parsed_body["integration"]["config"]
      expect(cfg["webhook_url"]).to eq(Integration::REDACTED)
      expect(cfg["webhook_url"]).not_to include("SECRET")
      expect(cfg["channel"]).to eq("#sales")
    end

    it "preserves the stored secret when the client echoes the redaction mask back" do
      patch "/api/v1/orgs/#{org.key}/integrations/#{integration.key}",
        params: { config: { "webhook_url" => Integration::REDACTED, "channel" => "#support" } },
        headers: headers
      expect(response).to have_http_status(:ok)
      integration.reload
      expect(integration.config["webhook_url"]).to eq("https://hooks.slack.com/services/SECRET")
      expect(integration.config["channel"]).to eq("#support")
    end

    it "updates the secret when a real new value is sent" do
      patch "/api/v1/orgs/#{org.key}/integrations/#{integration.key}",
        params: { config: { "webhook_url" => "https://hooks.slack.com/services/NEW" } },
        headers: headers
      expect(integration.reload.config["webhook_url"]).to eq("https://hooks.slack.com/services/NEW")
    end
  end
end
