require "rails_helper"
require "base64"
require "digest"
require "securerandom"

RSpec.describe "Api::V1::DeviceLink", type: :request do
  # Device-link (loopback + PKCE): a native client links to an account without
  # pasting a key. authorize (session-authed approval) → token (public PKCE
  # redemption → device-scoped ink_ key). See docs/Device-Link.md.
  let(:user) { create(:user, username: "linkuser") }
  let(:headers) { auth_headers(user) }

  let(:verifier) { SecureRandom.urlsafe_base64(48) }
  let(:challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }
  let(:redirect_uri) { "http://127.0.0.1:53117/cb" }

  def authorize_params(overrides = {})
    {
      code_challenge: challenge,
      code_challenge_method: "S256",
      redirect_uri: redirect_uri,
      device_name: "Waseem's MacBook",
      platform: "desktop"
    }.merge(overrides)
  end

  describe "POST /api/v1/auth/device-link/authorize" do
    it "mints a pending PKCE-bound code for the logged-in user" do
      expect {
        post "/api/v1/auth/device-link/authorize", params: authorize_params, headers: headers
      }.to change(DeviceLinkRequest, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["code"]).to start_with("dlc_")
      expect(body["redirect_uri"]).to eq(redirect_uri)

      req = DeviceLinkRequest.last
      expect(req.user).to eq(user)
      expect(req.status).to eq(DeviceLinkRequest::STATUS_PENDING)
      expect(req.device_name).to eq("Waseem's MacBook")
    end

    it "requires authentication" do
      post "/api/v1/auth/device-link/authorize", params: authorize_params
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a non-loopback redirect_uri (code-exfiltration guard)" do
      post "/api/v1/auth/device-link/authorize",
        params: authorize_params(redirect_uri: "https://evil.example.com/cb"), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects an unknown platform" do
      post "/api/v1/auth/device-link/authorize",
        params: authorize_params(platform: "toaster"), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a non-S256 challenge method" do
      post "/api/v1/auth/device-link/authorize",
        params: authorize_params(code_challenge_method: "plain"), headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "POST /api/v1/auth/device-link/token" do
    # Run the real authorize step first, then redeem the returned code.
    def approve!
      post "/api/v1/auth/device-link/authorize", params: authorize_params, headers: headers
      response.parsed_body["code"]
    end

    it "accepts the command-line client as a platform" do
      post "/api/v1/auth/device-link/authorize", params: authorize_params.merge(platform: "cli"), headers: headers
      expect(response).to have_http_status(:success)
    end

    it "redeems the code for a device-scoped ink_ key (no session needed)" do
      code = approve!

      expect {
        post "/api/v1/auth/device-link/token",
          params: { code: code, code_verifier: verifier, redirect_uri: redirect_uri }
      }.to change(ApiKey, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["token"]).to start_with("ink_")
      expect(body["api_key"]["device_platform"]).to eq("desktop")
      expect(body["api_key"]["name"]).to eq("Waseem's MacBook")
      expect(body["user"]["id"]).to eq(user.key)

      key = ApiKey.last
      expect(key.user).to eq(user)
      expect(key.scopes).to match_array(ApiKey::SCOPES)
      # The minted token actually authenticates as the user.
      expect(ApiKey.authenticate(body["token"]).user).to eq(user)
    end

    it "is single-use — the code can't be redeemed twice" do
      code = approve!
      post "/api/v1/auth/device-link/token",
        params: { code: code, code_verifier: verifier, redirect_uri: redirect_uri }
      expect(response).to have_http_status(:created)

      expect {
        post "/api/v1/auth/device-link/token",
          params: { code: code, code_verifier: verifier, redirect_uri: redirect_uri }
      }.not_to change(ApiKey, :count)
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a wrong PKCE verifier" do
      code = approve!
      post "/api/v1/auth/device-link/token",
        params: { code: code, code_verifier: "not-the-verifier", redirect_uri: redirect_uri }
      expect(response).to have_http_status(:bad_request)
      expect(ApiKey.count).to eq(0)
    end

    it "rejects a redirect_uri that doesn't match the approved one" do
      code = approve!
      post "/api/v1/auth/device-link/token",
        params: { code: code, code_verifier: verifier, redirect_uri: "http://127.0.0.1:9999/cb" }
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an expired code" do
      code = approve!
      DeviceLinkRequest.last.update!(expires_at: 1.minute.ago)
      post "/api/v1/auth/device-link/token",
        params: { code: code, code_verifier: verifier, redirect_uri: redirect_uri }
      expect(response).to have_http_status(:bad_request)
      expect(ApiKey.count).to eq(0)
    end

    it "rejects an unknown / malformed code" do
      post "/api/v1/auth/device-link/token",
        params: { code: "dlc_deadbeef", code_verifier: verifier, redirect_uri: redirect_uri }
      expect(response).to have_http_status(:bad_request)
    end
  end
end
