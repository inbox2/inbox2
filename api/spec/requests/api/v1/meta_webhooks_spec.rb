require "rails_helper"

# Meta webhook receiver (unauthenticated; verified by handshake token + on-device HMAC).
# See docs/Cloud-Push.md (Meta).
RSpec.describe "Api::V1::MetaWebhooks", type: :request do
  let(:user) { create(:user, username: "metahook") }

  describe "GET /api/v1/push/meta (verification handshake)" do
    it "echoes hub.challenge when no token is configured (dev/test)" do
      allow(MetaConfig).to receive(:verify_token).and_return(nil)
      get "/api/v1/push/meta", params: { "hub.mode" => "subscribe", "hub.challenge" => "CHAL123", "hub.verify_token" => "x" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("CHAL123")
    end

    it "echoes hub.challenge when the token matches" do
      allow(MetaConfig).to receive(:verify_token).and_return("tok")
      get "/api/v1/push/meta", params: { "hub.challenge" => "CHAL123", "hub.verify_token" => "tok" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("CHAL123")
    end

    it "rejects a mismatched token" do
      allow(MetaConfig).to receive(:verify_token).and_return("tok")
      get "/api/v1/push/meta", params: { "hub.challenge" => "CHAL123", "hub.verify_token" => "wrong" }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST /api/v1/push/meta (receiver)" do
    let(:raw_body) do
      {
        object: "whatsapp_business_account",
        entry: [{ id: "WABA1", changes: [{ field: "messages", value: { metadata: { phone_number_id: "PNID1" } } }] }]
      }.to_json
    end

    def post_raw(body, signature: "sha256=abc")
      post "/api/v1/push/meta", params: body,
        headers: { "CONTENT_TYPE" => "application/json", "X-Hub-Signature-256" => signature }
    end

    it "routes to the owning user, buffers the BYTE-EXACT body + signature, and fans out" do
      create(:meta_channel_subscription, user: user, channel: "whatsapp", asset_type: "phone", asset_id: "PNID1")

      expect(MetaWebhookBroadcaster).to receive(:call).with(an_instance_of(MetaWebhookEvent)).and_call_original

      expect { post_raw(raw_body, signature: "sha256=sig123") }
        .to change(MetaWebhookEvent, :count).by(1)

      expect(response).to have_http_status(:ok)
      event = MetaWebhookEvent.last
      expect(event.user).to eq(user)
      expect(event.object).to eq("whatsapp_business_account")
      expect(event.asset_id).to eq("PNID1")
      # Byte-exact preservation is what makes on-device HMAC verification work.
      expect(event.raw_payload).to eq(raw_body)
      expect(event.signature_header).to eq("sha256=sig123")
    end

    it "dedups Meta retries (identical body → one buffered event)" do
      create(:meta_channel_subscription, user: user, channel: "whatsapp", asset_type: "phone", asset_id: "PNID1")

      post_raw(raw_body)
      expect {
        post_raw(raw_body) # retry, same bytes
      }.not_to change(MetaWebhookEvent, :count)
      expect(response).to have_http_status(:ok)
    end

    it "accepts + drops an event for an unknown asset (no row, still 200)" do
      expect(MetaWebhookBroadcaster).not_to receive(:call)
      expect { post_raw(raw_body) }.not_to change(MetaWebhookEvent, :count)
      expect(response).to have_http_status(:ok)
    end

    it "routes a Page object by entry[].id" do
      create(:meta_channel_subscription, user: user, channel: "messenger", asset_type: "page", asset_id: "PAGE9")
      body = { object: "page", entry: [{ id: "PAGE9", messaging: [] }] }.to_json
      expect { post_raw(body) }.to change(MetaWebhookEvent, :count).by(1)
      expect(MetaWebhookEvent.last.asset_id).to eq("PAGE9")
    end
  end
end
