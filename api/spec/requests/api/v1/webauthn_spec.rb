require "rails_helper"
require "webauthn/fake_client"

RSpec.describe "Api::V1::Webauthn", type: :request do
  let(:user) { create(:user, username: "webauthnuser") }
  let(:headers) { auth_headers(user) }

  describe "POST /api/v1/auth/webauthn/registration-options (spec 2.1.5, A1.9)" do
    it "returns WebAuthn creation options" do
      post "/api/v1/auth/webauthn/registration-options", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["user"]["name"]).to eq("webauthnuser")
      expect(body["challenge"]).to be_present
      expect(body["rp"]["name"]).to eq("Inbox2")
    end

    context "with a session older than the re-auth window" do
      before { headers; Session.update_all(created_at: 1.hour.ago) }

      it "refuses without the password — a stolen session can't mint a passkey" do
        post "/api/v1/auth/webauthn/registration-options", headers: headers
        expect(response).to have_http_status(:unauthorized)
        post "/api/v1/auth/webauthn/registration-options", params: { password: "wrong" }, headers: headers
        expect(response).to have_http_status(:unauthorized)
      end

      it "allows it with the password" do
        post "/api/v1/auth/webauthn/registration-options", params: { password: "password123" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["challenge"]).to be_present
      end
    end

    it "generates webauthn_id for user if missing" do
      expect(user.webauthn_id).to be_nil
      post "/api/v1/auth/webauthn/registration-options", headers: headers
      expect(user.reload.webauthn_id).to be_present
    end
  end

  describe "GET /api/v1/auth/webauthn/authenticate-options" do
    it "returns WebAuthn get options without auth" do
      get "/api/v1/auth/webauthn/authenticate-options", params: { username: user.username }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["challenge"]).to be_present
    end
  end

  describe "GET /api/v1/auth/webauthn/credentials" do
    it "lists user credentials" do
      WebauthnCredential.create!(
        user: user,
        external_id: "cred_test_123",
        public_key: "pk_test",
        nickname: "My YubiKey"
      )

      get "/api/v1/auth/webauthn/credentials", headers: headers
      expect(response).to have_http_status(:ok)
      creds = response.parsed_body["credentials"]
      expect(creds.length).to eq(1)
      expect(creds.first["nickname"]).to eq("My YubiKey")
    end
  end

  describe "DELETE /api/v1/auth/webauthn/credentials/:id" do
    it "deletes a credential" do
      cred = WebauthnCredential.create!(
        user: user,
        external_id: "cred_to_delete",
        public_key: "pk_test",
        nickname: "Old Key"
      )

      expect {
        delete "/api/v1/auth/webauthn/credentials/#{cred.external_id}", headers: headers
      }.to change(WebauthnCredential, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "POST /api/v1/auth/webauthn/register" do
    it "rejects invalid credential data" do
      # Get options first to set up challenge
      post "/api/v1/auth/webauthn/registration-options", headers: headers

      post "/api/v1/auth/webauthn/register",
           params: { credential: { invalid: true } },
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # The whole ceremony against a software authenticator: register a passkey with
  # a session, then sign in with it and nothing else.
  describe "register → authenticate round trip (spec 2.1.5, A1.9)" do
    let(:client) { WebAuthn::FakeClient.new(WebAuthn.configuration.allowed_origins.first) }

    def register!(user_verified: true)
      post "/api/v1/auth/webauthn/registration-options", headers: headers
      credential = client.create(challenge: response.parsed_body["challenge"], user_verified: user_verified)
      post "/api/v1/auth/webauthn/register", params: { credential: credential, nickname: "Laptop" }, headers: headers, as: :json
    end

    it "registers a passkey, then signs in with it and no password" do
      register!
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["nickname"]).to eq("Laptop")

      get "/api/v1/auth/webauthn/authenticate-options"
      assertion = client.get(challenge: response.parsed_body["challenge"], user_verified: true)
      post "/api/v1/auth/webauthn/authenticate", params: { credential: assertion }, as: :json
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user"]["username"]).to eq("webauthnuser")
      expect(Session.find_by_token(response.parsed_body["token"]).user).to eq(user)
    end

    it "rejects a replayed assertion (challenge is single-use)" do
      register!
      get "/api/v1/auth/webauthn/authenticate-options"
      assertion = client.get(challenge: response.parsed_body["challenge"], user_verified: true)
      post "/api/v1/auth/webauthn/authenticate", params: { credential: assertion }, as: :json
      post "/api/v1/auth/webauthn/authenticate", params: { credential: assertion }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "won't register a challenge under a different user's token" do
      post "/api/v1/auth/webauthn/registration-options", headers: headers
      credential = client.create(challenge: response.parsed_body["challenge"], user_verified: true)
      other = create(:user, username: "someoneelse")
      post "/api/v1/auth/webauthn/register", params: { credential: credential }, headers: auth_headers(other), as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(WebauthnCredential.count).to eq(0)
    end

    it "rejects a passkey that did not verify the user" do
      register!(user_verified: false)
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.webauthn_credentials).to be_empty
    end

    it "rejects sign-in without a credential" do
      get "/api/v1/auth/webauthn/authenticate-options"
      post "/api/v1/auth/webauthn/authenticate", params: {}, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PUT /api/v1/auth/webauthn/requirement — require a passkey to sign in" do
    def add_passkey(name)
      WebauthnCredential.create!(user: user, external_id: name, public_key: "pk", nickname: name)
    end

    def login(extra = {})
      post "/api/v1/auth/login", params: { username: user.username, password: "password123" }.merge(extra)
    end

    it "refuses with a single passkey and no other second factor" do
      add_passkey("one")
      put "/api/v1/auth/webauthn/requirement", params: { required: true }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.passkey_required).to be(false)
    end

    it "turns on with two passkeys; a password alone then no longer signs in" do
      add_passkey("one"); add_passkey("two")
      put "/api/v1/auth/webauthn/requirement", params: { required: true }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["required"]).to be(true)

      login
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["requires_passkey"]).to be(true)
      expect(response.parsed_body["token"]).to be_nil
    end

    it "does not reveal the requirement to a wrong password" do
      add_passkey("one"); add_passkey("two")
      user.update!(passkey_required: true)
      login(password: "wrong")
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).not_to have_key("requires_passkey")
    end

    it "blocks removing a passkey that the requirement depends on, until it is turned off" do
      add_passkey("one"); add_passkey("two")
      user.update!(passkey_required: true)
      delete "/api/v1/auth/webauthn/credentials/one", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.webauthn_credentials.count).to eq(2)

      # Turning it off is a downgrade: the session alone isn't enough.
      put "/api/v1/auth/webauthn/requirement", params: { required: false }, headers: headers
      expect(response).to have_http_status(:unauthorized)
      expect(user.reload.passkey_required).to be(true)

      put "/api/v1/auth/webauthn/requirement", params: { required: false, password: "password123" }, headers: headers
      expect(response).to have_http_status(:ok)
      delete "/api/v1/auth/webauthn/credentials/one", headers: headers
      expect(response).to have_http_status(:no_content)
      login
      expect(response.parsed_body["token"]).to be_present
    end

    it "keeps TOTP while it is the requirement's only fallback" do
      add_passkey("one")
      secret = ROTP::Base32.random
      user.update!(totp_secret: secret, totp_enabled: true)
      put "/api/v1/auth/webauthn/requirement", params: { required: true }, headers: headers
      expect(response).to have_http_status(:ok)

      delete "/api/v1/auth/2fa/totp", params: { password: "password123", code: ROTP::TOTP.new(secret).now }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.totp_enabled).to be(true)
    end

    it "requires auth" do
      put "/api/v1/auth/webauthn/requirement", params: { required: true }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
