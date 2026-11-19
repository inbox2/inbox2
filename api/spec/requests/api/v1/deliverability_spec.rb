require "rails_helper"

RSpec.describe "Api::V1::Deliverability", type: :request do
  # E1 mapping: spec 20.3, A18.11 — per-org deliverability provider choice
  let(:owner) { create(:user, username: "delivowner") }
  let(:org) { create(:organization, owner: owner, domain: "deliv.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/deliverability" do
    it "defaults to the built-in mode and lists the provider catalog" do
      get "/api/v1/orgs/#{org.key}/deliverability", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body["deliverability"]
      expect(body["mode"]).to eq("builtin")
      kinds = body["providers"].map { |p| p["kind"] }
      expect(kinds).to include("ses", "sendgrid", "mailgun", "postmark", "messy", "smtp_relay")
      # Every provider carries an icon + label for the picker.
      body["providers"].each do |p|
        expect(p["icon"]).to be_present
        expect(p["label"]).to be_present
      end
    end

    it "requires authentication" do
      get "/api/v1/orgs/#{org.key}/deliverability"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PUT /api/v1/orgs/:org_id/deliverability" do
    it "switches to a custom provider and never echoes the secret back" do
      put "/api/v1/orgs/#{org.key}/deliverability",
          params: { mode: "custom", kind: "sendgrid", config: { api_key: "SG.supersecret" } },
          headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body["deliverability"]
      expect(body["mode"]).to eq("custom")
      expect(body["kind"]).to eq("sendgrid")
      # E4: secret is write-only — only a presence flag comes back.
      expect(body["config"]).not_to have_key("api_key")
      expect(body["config"]["api_key_set"]).to be(true)

      # The active channel really did flip.
      expect(DeliveryChannel.active_for(org).kind).to eq("sendgrid")
      expect(org.delivery_channels.find_by(kind: "sendgrid").config["api_key"]).to eq("SG.supersecret")
    end

    it "keeps an untouched secret when re-saving without it" do
      org.delivery_channels.create!(name: "SendGrid", kind: "sendgrid", status: "active", is_default: true, config: { "api_key" => "SG.keep" })
      put "/api/v1/orgs/#{org.key}/deliverability",
          params: { mode: "custom", kind: "sendgrid", config: { api_key: "" } },
          headers: headers
      expect(response).to have_http_status(:ok)
      expect(org.delivery_channels.find_by(kind: "sendgrid").config["api_key"]).to eq("SG.keep")
    end

    it "switches back to the built-in" do
      org.delivery_channels.create!(name: "SendGrid", kind: "sendgrid", status: "active", is_default: true, config: { "api_key" => "x" })
      put "/api/v1/orgs/#{org.key}/deliverability", params: { mode: "builtin" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["deliverability"]["mode"]).to eq("builtin")
      expect(DeliveryChannel.active_for(org)).to be_builtin
    end

    it "rejects an unknown provider kind" do
      put "/api/v1/orgs/#{org.key}/deliverability", params: { mode: "custom", kind: "pigeon" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is tenant-isolated (E3): a non-member cannot configure another org" do
      stranger = create(:user, username: "stranger")
      put "/api/v1/orgs/#{org.key}/deliverability",
          params: { mode: "custom", kind: "sendgrid", config: { api_key: "x" } },
          headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found).or have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/orgs/:org_id/deliverability/test" do
    it "pre-flights a provider via its verify path" do
      allow_any_instance_of(DeliveryProviders::Sendgrid).to receive(:verify).and_return(DeliveryProviders::Result.ok)
      post "/api/v1/orgs/#{org.key}/deliverability/test",
           params: { kind: "sendgrid", config: { api_key: "SG.x" } }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("ok")
    end

    it "reports a failed connection" do
      allow_any_instance_of(DeliveryProviders::Sendgrid).to receive(:verify).and_return(DeliveryProviders::Result.permanent_failure("bad key"))
      post "/api/v1/orgs/#{org.key}/deliverability/test",
           params: { kind: "sendgrid", config: { api_key: "nope" } }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("error")
      expect(response.parsed_body["message"]).to include("bad key")
    end
  end
end
