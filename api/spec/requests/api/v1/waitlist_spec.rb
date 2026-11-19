require "rails_helper"

RSpec.describe "Api::V1::Waitlist", type: :request do
  def json = response.parsed_body

  let(:valid_params) do
    {
      name: "Dana Scully",
      company: "FBI",
      email: "dana@example.com",
      industry: "developer",
      email_services: { gmail_count: 2, office365_count: 1, others: ["Fastmail"] },
      social_accounts: { whatsapp_count: 1, meta_count: 0, messenger_count: 0, others: ["Telegram"] }
    }
  end

  describe "POST /api/v1/waitlist" do
    it "creates a signup, persists the structured fields, and enqueues a notification" do
      expect {
        post "/api/v1/waitlist", params: valid_params
      }.to change(WaitlistSignup, :count).by(1).and have_enqueued_job(MessyTriggerJob)

      expect(response).to have_http_status(:accepted)
      s = WaitlistSignup.last
      expect(s.email).to eq("dana@example.com")
      expect(s.email_services["gmail_count"]).to eq(2)
      expect(s.email_services["office365_count"]).to eq(1)
      expect(s.social_accounts["whatsapp_count"]).to eq(1)
      expect(s.social_accounts["others"]).to eq(["Telegram"])
    end

    it "stores the optional note and the admin email shows it with the industry label" do
      post "/api/v1/waitlist", params: valid_params.merge(industry_note: "  one inbox for sales@  ")
      s = WaitlistSignup.last
      expect(s.industry_note).to eq("one inbox for sales@")

      html = WaitlistMailerService.send(:render, "admin_notification", signup: s)
      expect(html).to include("Developer / Engineering", "one inbox for sales@", "Gmail × 2")
    end

    it "does not leak existence: duplicate email returns the same 202 and creates nothing new" do
      create(:waitlist_signup, email: "dana@example.com")
      expect {
        post "/api/v1/waitlist", params: valid_params
      }.not_to change(WaitlistSignup, :count)
      expect(response).to have_http_status(:accepted)
      expect(MessyTriggerJob).not_to have_been_enqueued
    end

    it "normalizes case so a differently-cased duplicate still doesn't create" do
      create(:waitlist_signup, email: "dana@example.com")
      expect {
        post "/api/v1/waitlist", params: valid_params.merge(email: "DANA@example.com")
      }.not_to change(WaitlistSignup, :count)
      expect(response).to have_http_status(:accepted)
    end

    it "422s on invalid input (independent of existence — no enumeration)" do
      post "/api/v1/waitlist", params: valid_params.merge(email: "nope")
      expect(response).to have_http_status(:unprocessable_content)

      post "/api/v1/waitlist", params: valid_params.merge(name: "")
      expect(response).to have_http_status(:unprocessable_content)
    end

    context "with Turnstile configured" do
      around do |ex|
        orig = ENV["TURNSTILE_SECRET"]
        ENV["TURNSTILE_SECRET"] = "test-secret"
        ex.run
        ENV["TURNSTILE_SECRET"] = orig
      end

      it "rejects when the token fails verification" do
        allow(TurnstileVerifier).to receive(:verify).and_return(false)
        expect {
          post "/api/v1/waitlist", params: valid_params.merge(turnstile_token: "bad")
        }.not_to change(WaitlistSignup, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "accepts when the token passes" do
        allow(TurnstileVerifier).to receive(:verify).and_return(true)
        post "/api/v1/waitlist", params: valid_params.merge(turnstile_token: "good")
        expect(response).to have_http_status(:accepted)
      end
    end
  end

  describe "GET /api/v1/waitlist/config" do
    it "reports the gate state and site key" do
      get "/api/v1/waitlist/config"
      expect(response).to have_http_status(:ok)
      expect(json).to have_key("invite_enabled")
      expect(json).to have_key("turnstile_site_key")
    end
  end

  describe "GET /api/v1/waitlist/invite" do
    it "returns prefill for a redeemable token" do
      s = create(:waitlist_signup, :invited)
      get "/api/v1/waitlist/invite", params: { token: s.invite_token }
      expect(response).to have_http_status(:ok)
      expect(json["email"]).to eq(s.email)
      expect(json["name"]).to eq(s.name)
    end

    it "404s for an unknown/expired token" do
      get "/api/v1/waitlist/invite", params: { token: "nope" }
      expect(response).to have_http_status(:not_found)
    end
  end
end
