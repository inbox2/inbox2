require "rails_helper"

RSpec.describe "Api::V1::Saas::WaitlistSignups", :saas, type: :request do
  let(:credential) { create(:admin_credential) }
  let(:headers) { saas_headers(credential) }

  def json = response.parsed_body

  describe "GET /index" do
    it "lists signups and filters by q (name/email/company)" do
      create(:waitlist_signup, name: "Alice Dev", email: "alice@acme.test", company: "Acme")
      create(:waitlist_signup, name: "Bob Design", email: "bob@globex.test", company: "Globex")

      get "/api/v1/saas/waitlist_signups", params: { q: "acme" }, headers: headers

      expect(response).to have_http_status(:ok)
      emails = json["waitlist_signups"].map { |s| s["email"] }
      expect(emails).to include("alice@acme.test")
      expect(emails).not_to include("bob@globex.test")
      expect(json["meta"]).to include("total", "page", "per_page")
    end

    it "requires SaaS auth" do
      get "/api/v1/saas/waitlist_signups"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /show" do
    it "returns the full submitted detail" do
      s = create(:waitlist_signup)
      get "/api/v1/saas/waitlist_signups/#{s.key}", headers: headers
      expect(response).to have_http_status(:ok)
      body = json["waitlist_signup"]
      expect(body["id"]).to eq(s.key)
      expect(body["email_services"]).to include("gmail_count" => 2)
      expect(body).not_to have_key("invite_token")
    end

    it "404s for an unknown entry" do
      get "/api/v1/saas/waitlist_signups/wls_missing", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /invite" do
    it "mints a token, sends the invite, and writes an audit log" do
      s = create(:waitlist_signup)

      expect {
        post "/api/v1/saas/waitlist_signups/#{s.key}/invite", headers: headers
      }.to have_enqueued_job(MessyTriggerJob)

      expect(response).to have_http_status(:ok)
      expect(json["waitlist_signup"]["status"]).to eq(WaitlistSignup::STATUS_INVITED)
      expect(s.reload.invite_token).to be_present
      expect(s.invited_by).to eq(credential.key)

      log = SaasAuditLog.last
      expect(log.action).to eq(SaasAuditLog::ACTION_WAITLIST_INVITE)
      expect(log.target_key).to eq(s.key)
    end

    it "requires SaaS auth" do
      s = create(:waitlist_signup)
      post "/api/v1/saas/waitlist_signups/#{s.key}/invite"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
