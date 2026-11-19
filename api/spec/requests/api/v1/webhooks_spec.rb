require "rails_helper"

RSpec.describe "Api::V1::Webhooks", type: :request do
  let(:owner) { create(:user, username: "whkowner") }
  let(:org) { create(:organization, owner: owner, domain: "webhooks.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/webhooks" do
    it "lists webhooks" do
      create(:webhook, organization: org, url: "https://example.com/hook1")
      get "/api/v1/orgs/#{org.key}/webhooks", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["webhooks"].length).to eq(1)
      # Secret should never be exposed
      expect(response.parsed_body["webhooks"].first).not_to have_key("secret")
    end
  end

  describe "POST /api/v1/orgs/:org_id/webhooks" do
    it "creates a webhook" do
      post "/api/v1/orgs/#{org.key}/webhooks",
           params: { url: "https://example.com/new-hook", secret: "s3cret" },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["webhook"]["url"]).to eq("https://example.com/new-hook")
      expect(response.parsed_body["webhook"]["id"]).to start_with("whk_")
    end

    # spec 7.4.6-7.4.7 — Custom payloads
    it "creates a webhook with custom payload_template and events" do
      post "/api/v1/orgs/#{org.key}/webhooks",
           params: {
             url: "https://slack.com/webhook",
             events: [Webhook::EVENT_MESSAGE_CREATED, Webhook::EVENT_CONVERSATION_ASSIGNED],
             payload_template: { text: "New: {{conversation.subject}}" }
           },
           headers: headers
      expect(response).to have_http_status(:created)
      webhook = response.parsed_body["webhook"]
      expect(webhook["events"]).to include(Webhook::EVENT_MESSAGE_CREATED)
      expect(webhook["payload_template"]).to be_present
    end

    it "rejects invalid events" do
      post "/api/v1/orgs/#{org.key}/webhooks",
           params: { url: "https://example.com", events: ["invalid.event"] },
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/webhooks/:id" do
    let!(:webhook) { create(:webhook, organization: org) }

    it "updates webhook events and template" do
      patch "/api/v1/orgs/#{org.key}/webhooks/#{webhook.key}",
            params: { events: [Webhook::EVENT_RULE_MATCHED] },
            headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["webhook"]["events"]).to include(Webhook::EVENT_RULE_MATCHED)
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/webhooks/:id" do
    let!(:webhook) { create(:webhook, organization: org) }

    it "deletes a webhook" do
      expect {
        delete "/api/v1/orgs/#{org.key}/webhooks/#{webhook.key}", headers: headers
      }.to change(Webhook, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end
end
