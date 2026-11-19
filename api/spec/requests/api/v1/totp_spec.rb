require "rails_helper"

RSpec.describe "Api::V1::Totp", type: :request do
  # E1 mapping: spec 2.1.5, A1.8 — TOTP two-factor
  let(:user) { create(:user, username: "totpuser") }
  let(:headers) { auth_headers(user) }

  describe "POST /api/v1/auth/2fa/totp/enroll" do
    it "generates a TOTP secret and QR code" do
      post "/api/v1/auth/2fa/totp/enroll", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["secret"]).to be_present
      expect(body["provisioning_uri"]).to include("otpauth://")
      expect(body["qr_svg"]).to include("<svg")
      expect(user.reload.totp_secret).to be_present
    end
  end

  describe "POST /api/v1/auth/2fa/totp/verify" do
    it "enables TOTP with valid code" do
      # Enroll first
      post "/api/v1/auth/2fa/totp/enroll", headers: headers
      secret = user.reload.totp_secret

      # Generate valid code
      totp = ROTP::TOTP.new(secret)
      code = totp.now

      post "/api/v1/auth/2fa/totp/verify", params: { code: code }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(user.reload.totp_enabled).to eq(true)
    end

    it "rejects invalid code" do
      user.update!(totp_secret: ROTP::Base32.random)
      post "/api/v1/auth/2fa/totp/verify", params: { code: "000000" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /api/v1/auth/2fa/totp" do
    it "disables TOTP with the password and a current code" do
      secret = ROTP::Base32.random
      user.update!(totp_secret: secret, totp_enabled: true)
      code = ROTP::TOTP.new(secret).now

      delete "/api/v1/auth/2fa/totp", params: { password: "password123", code: code }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(user.reload.totp_enabled).to eq(false)
      expect(user.totp_secret).to be_nil
    end

    it "rejects disable without the password (stolen-session protection)" do
      user.update!(totp_secret: ROTP::Base32.random, totp_enabled: true)
      delete "/api/v1/auth/2fa/totp", params: { code: "000000" }, headers: headers
      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.totp_enabled).to eq(true)
    end

    it "rejects disable with a wrong code" do
      user.update!(totp_secret: ROTP::Base32.random, totp_enabled: true)
      delete "/api/v1/auth/2fa/totp", params: { password: "password123", code: "000000" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.totp_enabled).to eq(true)
    end
  end
end
