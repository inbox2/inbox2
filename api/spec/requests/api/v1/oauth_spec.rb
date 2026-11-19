require "rails_helper"

RSpec.describe "Api::V1::Oauth", type: :request do
  let(:user) { create(:user, username: "oauthuser") }
  let(:headers) { auth_headers(user) }

  describe "GET /api/v1/auth/oauth/providers (spec 2.1.6, A1.10)" do
    it "lists available OAuth providers" do
      get "/api/v1/auth/oauth/providers", headers: headers
      expect(response).to have_http_status(:ok)
      providers = response.parsed_body["providers"]
      expect(providers.map { |p| p["name"] }).to include(OauthIdentity::PROVIDER_GOOGLE, OauthIdentity::PROVIDER_MICROSOFT)
    end
  end

  describe "POST /api/v1/auth/oauth/callback" do
    # Identity is derived from the provider-verified token, never from client params.
    def stub_verify(uid:, email:, name: "New User")
      allow(OauthVerifier).to receive(:verify).and_return(
        OauthVerifier::Identity.new(uid: uid, email: email, name: name)
      )
    end

    it "creates new user from a provider-verified token and returns a session" do
      stub_verify(uid: "google_123456", email: "newuser@gmail.com")
      post "/api/v1/auth/oauth/callback", params: {
        provider: OauthIdentity::PROVIDER_GOOGLE,
        access_token: "at_test_token"
      }
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["token"]).to be_present
      expect(body["user"]["username"]).to be_present
    end

    it "logs in existing user by OAuth identity" do
      OauthIdentity.create!(
        user: user,
        provider: OauthIdentity::PROVIDER_GOOGLE,
        uid: "google_existing",
        email: "oauthuser@gmail.com"
      )
      stub_verify(uid: "google_existing", email: "oauthuser@gmail.com")

      post "/api/v1/auth/oauth/callback", params: {
        provider: OauthIdentity::PROVIDER_GOOGLE,
        access_token: "at_test_token"
      }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["user"]["id"]).to eq(user.key)
    end

    it "ignores client-supplied uid/email — only the provider-verified identity is used" do
      OauthIdentity.create!(user: user, provider: OauthIdentity::PROVIDER_GOOGLE, uid: "real_uid", email: "victim@gmail.com")
      # Attacker posts the victim's uid, but the token verifies to someone else.
      stub_verify(uid: "attacker_uid", email: "attacker@gmail.com")

      post "/api/v1/auth/oauth/callback", params: {
        provider: OauthIdentity::PROVIDER_GOOGLE,
        uid: "real_uid",
        email: "victim@gmail.com",
        access_token: "at_attacker"
      }
      expect(response).to have_http_status(:ok)
      # Logged in as the verified identity's (new) account, NOT the victim.
      expect(response.parsed_body["user"]["id"]).not_to eq(user.key)
    end

    it "rejects a token the provider cannot verify" do
      allow(OauthVerifier).to receive(:verify).and_return(nil)
      post "/api/v1/auth/oauth/callback", params: {
        provider: OauthIdentity::PROVIDER_GOOGLE,
        access_token: "bogus"
      }
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a missing access token" do
      post "/api/v1/auth/oauth/callback", params: { provider: OauthIdentity::PROVIDER_GOOGLE }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects unknown provider" do
      post "/api/v1/auth/oauth/callback", params: { provider: "unknown", access_token: "x" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "GET /api/v1/auth/oauth/identities" do
    it "lists linked identities" do
      OauthIdentity.create!(
        user: user,
        provider: OauthIdentity::PROVIDER_GOOGLE,
        uid: "google_list",
        email: "user@gmail.com",
        name: "OAuth User"
      )

      get "/api/v1/auth/oauth/identities", headers: headers
      expect(response).to have_http_status(:ok)
      identities = response.parsed_body["identities"]
      expect(identities.length).to eq(1)
      expect(identities.first["provider"]).to eq(OauthIdentity::PROVIDER_GOOGLE)
    end
  end

  describe "DELETE /api/v1/auth/oauth/identities/:provider" do
    it "unlinks an identity" do
      OauthIdentity.create!(
        user: user,
        provider: OauthIdentity::PROVIDER_GOOGLE,
        uid: "google_unlink",
        email: "user@gmail.com"
      )

      expect {
        delete "/api/v1/auth/oauth/identities/#{OauthIdentity::PROVIDER_GOOGLE}", headers: headers
      }.to change(OauthIdentity, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end
end
