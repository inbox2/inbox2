require "rails_helper"

# E1 mapping: spec 21.1 — ESP, application side (docs/ESP.md)
RSpec.describe "ESP emails API", type: :request do
  let(:org) { create(:organization, domain: "acme.test", plan: Plan.paid) }
  let(:key) { create(:esp_key, organization: org) }
  let(:headers) { { "Authorization" => "Bearer #{key.raw_token}" } }
  let(:valid) { { from: "Acme <app@acme.test>", to: ["rcpt@example.com"], subject: "Receipt", text: "Thanks", html: "<p>Thanks</p>" } }

  def send_email(params = valid, extra_headers = {})
    post "/api/v1/esp/emails", params: params, headers: headers.merge(extra_headers), as: :json
  end

  describe "POST /api/v1/esp/emails" do
    it "accepts a send, stores the message and queues one delivery per recipient (21.1.1)" do
      expect {
        send_email(valid.merge(to: ["a@example.com", "b@example.com"], bcc: ["c@example.com"], tag: "receipt"))
      }.to have_enqueued_job(Esp::DeliverJob).exactly(3).times
      expect(response).to have_http_status(:accepted)
      email = response.parsed_body["email"]
      expect(email["id"]).to start_with("em_")
      expect(email["deliveries"].map { |d| d["status"] }).to eq(%w[queued queued queued])

      message = Esp::Message.find_by!(key: email["id"])
      mime = message.raw_mime
      expect(mime).to include("Subject: Receipt")
      expect(mime).not_to include("c@example.com") # Bcc is envelope-only
      expect(Conversation.count).to eq(0)          # never the domain's inbox
    end

    it "refuses a missing or revoked key (21.1.2)" do
      post "/api/v1/esp/emails", params: valid, as: :json
      expect(response).to have_http_status(:unauthorized)

      key.update!(revoked_at: Time.current)
      send_email
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a personal ink_ API key" do
      token = org.owner.api_keys.create!(name: "personal").raw_token
      post "/api/v1/esp/emails", params: valid, headers: { "Authorization" => "Bearer #{token}" }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a From domain that is another organization's (21.1.3, E3)" do
      create(:organization, domain: "other.test")
      send_email(valid.merge(from: "x@other.test"))
      expect(response).to have_http_status(:forbidden)
      expect(Esp::Message.count).to eq(0)
    end

    it "sends from a verified send-only domain, not from an unverified one (21.1.3)" do
      create(:esp_domain, organization: org, name: "mail.acme-app.example")
      send_email(valid.merge(from: "no-reply@mail.acme-app.example"))
      expect(response).to have_http_status(:accepted)

      create(:esp_domain, organization: org, name: "pending.example", status: Esp::Domain::STATUS_PENDING_DNS)
      send_email(valid.merge(from: "x@pending.example"))
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects a header that would inject another header (21.1.4)" do
      send_email(valid.merge(headers: { "X-Thing" => "ok\r\nBcc: evil@example.com" }))
      expect(response).to have_http_status(:unprocessable_content)

      send_email(valid.merge(headers: { "DKIM-Signature" => "v=1" }))
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a From that names more than one sender (21.1.3)" do
      create(:organization, domain: "other.test")
      send_email(valid.merge(from: "app@acme.test, ceo@other.test"))
      expect(response).to have_http_status(:unprocessable_content)
      expect(Esp::Message.count).to eq(0)
    end

    it "validates recipients and body" do
      send_email(valid.merge(to: ["not-an-address"]))
      expect(response).to have_http_status(:unprocessable_content)
      send_email(valid.except(:text, :html))
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns the first send for a repeated Idempotency-Key (21.1.5)" do
      send_email(valid, "Idempotency-Key" => "order-1")
      first = response.parsed_body["email"]["id"]
      # The repeat sends nothing new, and queues again what never left.
      expect { send_email(valid, "Idempotency-Key" => "order-1") }
        .to have_enqueued_job(Esp::DeliverJob).once.and(not_change(Esp::Delivery, :count))
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["email"]["id"]).to eq(first)
    end

    it "does not queue a suppressed recipient (21.1.6)" do
      SuppressionEntry.record!(org, "rcpt@example.com", reason: SuppressionEntry::REASON_HARD_BOUNCE)
      expect { send_email }.not_to have_enqueued_job(Esp::DeliverJob)
      expect(response.parsed_body["email"]["deliveries"].first["status"]).to eq("failed")
    end

    it "is not available on the free plan (21.1.7)" do
      org.update!(plan: Plan.free)
      send_email
      expect(response).to have_http_status(:forbidden)
    end

    it "answers 429 over the monthly allowance (21.1.7)" do
      stub_const("Plan::ESP_MONTHLY_SENDS", Plan::ESP_MONTHLY_SENDS.merge(Plan::TIER_PAID => 1))
      send_email
      expect(response).to have_http_status(:accepted)
      send_email
      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe "GET /api/v1/esp/emails" do
    it "lists and shows only this organization's sends (21.1.8, E3)" do
      mine = create(:esp_message, organization: org, esp_key: key)
      other = create(:esp_message)

      get "/api/v1/esp/emails", headers: headers
      expect(response.parsed_body["emails"].map { |e| e["id"] }).to eq([mine.key])

      get "/api/v1/esp/emails/#{mine.key}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["email"]).to have_key("events")

      get "/api/v1/esp/emails/#{other.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
