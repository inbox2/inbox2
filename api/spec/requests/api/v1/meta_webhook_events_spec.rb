require "rails_helper"

# Device fetch + ack of buffered Meta webhook payloads. See docs/Cloud-Push.md (Meta).
RSpec.describe "Api::V1::MetaWebhookEvents", type: :request do
  let(:user) { create(:user, username: "metafetch") }
  let(:headers) { auth_headers(user) }

  describe "GET /api/v1/meta-webhook-events/:id" do
    it "returns the raw payload + signature for the device to verify (E1 positive)" do
      event = create(:meta_webhook_event, user: user, raw_payload: '{"object":"page"}',
        signature_header: "sha256=sig", object: "page")

      get "/api/v1/meta-webhook-events/#{event.key}", headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body["event"]
      expect(body["id"]).to eq(event.key)
      expect(body["raw_payload"]).to eq('{"object":"page"}')
      expect(body["signature_header"]).to eq("sha256=sig")
      expect(body["object"]).to eq("page")
    end

    it "does not leak another user's event (E3 → 404)" do
      other = create(:user, username: "metaother")
      event = create(:meta_webhook_event, user: other)
      get "/api/v1/meta-webhook-events/#{event.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "404s an expired (past-TTL) event" do
      event = create(:meta_webhook_event, user: user, received_at: (MetaWebhookEvent::TTL + 1.minute).ago)
      get "/api/v1/meta-webhook-events/#{event.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication (E1 negative)" do
      event = create(:meta_webhook_event, user: user)
      get "/api/v1/meta-webhook-events/#{event.key}"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /api/v1/meta-webhook-events/:id (ack)" do
    it "marks the event consumed (idempotent)" do
      event = create(:meta_webhook_event, user: user)

      delete "/api/v1/meta-webhook-events/#{event.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(event.reload.consumed_at).to be_present

      # Idempotent: acking again (or a missing row) is still success.
      delete "/api/v1/meta-webhook-events/#{event.key}", headers: headers
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "MetaWebhookEventSweeperJob" do
    it "purges only past-TTL events" do
      fresh = create(:meta_webhook_event, user: user, received_at: 1.minute.ago)
      stale = create(:meta_webhook_event, user: user, received_at: (MetaWebhookEvent::TTL + 1.hour).ago)

      MetaWebhookEventSweeperJob.new.perform

      expect(MetaWebhookEvent.exists?(fresh.id)).to be(true)
      expect(MetaWebhookEvent.exists?(stale.id)).to be(false)
    end
  end
end
