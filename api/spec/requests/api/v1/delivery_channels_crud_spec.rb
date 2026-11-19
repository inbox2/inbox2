require "rails_helper"

RSpec.describe "Api::V1::DeliveryChannels CRUD", type: :request do
  # E1 mapping: spec 20.1.1-20.2.8, A18.1-A18.10 — Delivery channels
  let(:owner) { create(:user, username: "dchowner") }
  let(:org) { create(:organization, owner: owner, domain: "dchcrud.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "POST /api/v1/orgs/:org_id/delivery-channels" do
    it "creates an external SMTP relay channel" do
      post "/api/v1/orgs/#{org.key}/delivery-channels",
           params: { name: "Postmark", kind: "smtp_relay", config: { host: "smtp.postmark.com", port: 587 } },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["delivery_channel"]["name"]).to eq("Postmark")
      expect(response.parsed_body["delivery_channel"]["kind"]).to eq("smtp_relay")
    end
  end

  describe "POST /api/v1/orgs/:org_id/delivery-channels/:id/test" do
    it "tests channel connectivity" do
      channel = DeliveryChannel.ensure_builtin(org)
      post "/api/v1/orgs/#{org.key}/delivery-channels/#{channel.key}/test", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("ok")
    end
  end

  describe "PUT /api/v1/orgs/:org_id/delivery-channels/default" do
    it "sets a channel as default" do
      channel = DeliveryChannel.ensure_builtin(org)
      put "/api/v1/orgs/#{org.key}/delivery-channels/set-default",
          params: { channel_id: channel.key }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(channel.reload.is_default).to eq(true)
    end
  end

  describe "GET /api/v1/orgs/:org_id/delivery-channels/:id/stats" do
    it "returns delivery statistics via the serializer" do
      channel = DeliveryChannel.ensure_builtin(org)
      get "/api/v1/orgs/#{org.key}/delivery-channels/#{channel.key}/stats", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.keys).to match_array(%w[channel_id total delivered failed bounced])
      # E5: public channel key, never the numeric id.
      expect(body["channel_id"]).to eq(channel.key)
    end
  end

  describe "GET /api/v1/orgs/:org_id/delivery-log" do
    it "returns org-wide delivery log" do
      get "/api/v1/orgs/#{org.key}/delivery-log", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to have_key("delivery_log")
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/delivery-channels/:id" do
    it "prevents deleting builtin channel" do
      channel = DeliveryChannel.ensure_builtin(org)
      delete "/api/v1/orgs/#{org.key}/delivery-channels/#{channel.key}", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "deletes an external channel" do
      channel = org.delivery_channels.create!(name: "Old Relay", kind: "smtp_relay", status: "disabled")
      delete "/api/v1/orgs/#{org.key}/delivery-channels/#{channel.key}", headers: headers
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "delivery channels — negative paths" do
    it "returns 404 testing an unknown channel" do
      post "/api/v1/orgs/#{org.key}/delivery-channels/dch_missing/test", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for stats on an unknown channel" do
      get "/api/v1/orgs/#{org.key}/delivery-channels/dch_missing/stats", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      post "/api/v1/orgs/#{org.key}/delivery-channels", params: { name: "X", kind: "smtp_relay" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
