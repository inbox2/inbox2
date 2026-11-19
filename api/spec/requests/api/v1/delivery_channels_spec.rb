require "rails_helper"

RSpec.describe "Api::V1::DeliveryChannels", type: :request do
  let(:owner) { create(:user, username: "delowner") }
  let(:org) { create(:organization, owner: owner, domain: "delivery.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # spec 20.1.1, A18.1
  describe "GET /api/v1/orgs/:org_id/delivery-channels" do
    it "lists delivery channels with builtin auto-created" do
      get "/api/v1/orgs/#{org.key}/delivery-channels", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["delivery_channels"].length).to be >= 1
      builtin = body["delivery_channels"].find { |c| c["kind"] == "builtin" }
      expect(builtin).to be_present
      expect(builtin["id"]).to start_with("dch_")
      expect(builtin["is_default"]).to eq(true)
    end
  end

  # spec 20.2.1, A18.9
  describe "GET /api/v1/orgs/:org_id/conversations/:id/messages/:msg_id/delivery" do
    let!(:conv) { create(:conversation, organization: org) }
    let!(:msg) { create(:message, conversation: conv, organization: org, is_inbound: false) }

    it "returns delivery status for an outbound message" do
      channel = DeliveryChannel.ensure_builtin(org)
      create(:delivery_status, message: msg, delivery_channel: channel, status: "delivered",
             delivered_at: Time.current, attempt_count: 1)

      get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/messages/#{msg.key}/delivery",
          headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["delivery"]["status"]).to eq("delivered")
      expect(body["delivery"]["id"]).to start_with("ds_")
    end

    it "returns null delivery when no tracking exists" do
      get "/api/v1/orgs/#{org.key}/conversations/#{conv.key}/messages/#{msg.key}/delivery",
          headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["delivery"]).to be_nil
    end
  end
end
