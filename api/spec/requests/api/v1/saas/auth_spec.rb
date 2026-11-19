require "rails_helper"

# Auth gate for the platform SaaS surface: mTLS client-cert fingerprint
# + IP allowlist, with NO bearer/user auth. Uses the dashboard endpoint as a
# representative protected route.
RSpec.describe "Api::V1::Saas auth", :saas, type: :request do
  let(:credential) { create(:admin_credential) }
  let(:path) { "/api/v1/saas/dashboard" }

  describe "client-cert authentication" do
    it "200s for a valid, verified fingerprint" do
      get path, headers: saas_headers(credential)
      expect(response).to have_http_status(:ok)
    end

    it "records last-used metadata for the operator" do
      expect {
        get path, headers: saas_headers(credential, ip: "203.0.113.7")
      }.to change { credential.reload.last_used_at }.from(nil)
      expect(credential.last_used_ip).to eq("203.0.113.7")
    end

    it "401s when header auth is not explicitly enabled, whatever the environment" do
      # Production used to trust the headers unconditionally — the whole plane
      # then rested on nobody sending `ssl-client-verify: SUCCESS` themselves.
      ENV["SAAS_ALLOW_HEADER_AUTH"] = nil
      allow(Rails.env).to receive(:production?).and_return(true)
      get path, headers: saas_headers(credential)
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when no client-cert headers are present" do
      get path
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s when the cert was not verified by the proxy" do
      get path, headers: saas_headers(credential, verify: "FAILED")
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s for an unknown fingerprint" do
      get path, headers: { "ssl-client-verify" => "SUCCESS", "ssl-client-fingerprint" => "deadbeef" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "401s for a revoked credential" do
      credential.update!(revoked_at: Time.current)
      get path, headers: saas_headers(credential)
      expect(response).to have_http_status(:unauthorized)
    end

    it "ignores injected headers when header-auth is not trusted (non-prod, flag off)" do
      ENV["SAAS_ALLOW_HEADER_AUTH"] = nil
      get path, headers: saas_headers(credential)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "IP allowlist" do
    around do |example|
      previous = ENV["SAAS_IP_ALLOWLIST"]
      ENV["SAAS_IP_ALLOWLIST"] = "10.0.0.0/8"
      example.run
      ENV["SAAS_IP_ALLOWLIST"] = previous
    end

    it "403s a client IP outside the allowlist (before auth runs)" do
      get path, headers: saas_headers(credential, ip: "203.0.113.9")
      expect(response).to have_http_status(:forbidden)
    end

    it "allows a client IP inside the allowlist" do
      get path, headers: saas_headers(credential, ip: "10.1.2.3")
      expect(response).to have_http_status(:ok)
    end
  end
end
