require "rails_helper"

RSpec.describe "Api::V1::ApiKeys", type: :request do
  # E1 mapping: spec 14.5, A17.1 — API keys
  let(:user) { create(:user, username: "akuser") }
  let(:headers) { auth_headers(user) }

  describe "POST /api/v1/account/api-keys" do
    it "creates an API key and returns the token once" do
      post "/api/v1/account/api-keys", params: { name: "My Key" }, headers: headers
      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["api_key"]["name"]).to eq("My Key")
      expect(body["token"]).to start_with("ink_")
      expect(body["api_key"]["id"]).to start_with("ak_")
    end
  end

  describe "GET /api/v1/account/api-keys" do
    it "lists API keys without exposing tokens" do
      user.api_keys.create!(name: "Test Key")
      get "/api/v1/account/api-keys", headers: headers
      expect(response).to have_http_status(:ok)
      keys = response.parsed_body["api_keys"]
      expect(keys.length).to eq(1)
      expect(keys.first).not_to have_key("token")
      expect(keys.first).not_to have_key("token_digest")
    end
  end

  describe "DELETE /api/v1/account/api-keys/:id" do
    it "deletes an API key" do
      key = user.api_keys.create!(name: "Deletable")
      expect {
        delete "/api/v1/account/api-keys/#{key.key}", headers: headers
      }.to change(ApiKey, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "api keys — negative paths" do
    it "returns 422 when name is missing" do
      post "/api/v1/account/api-keys", params: {}, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 404 when deleting another user's key" do
      other = create(:user, username: "akother")
      others_key = other.api_keys.create!(name: "Theirs")
      delete "/api/v1/account/api-keys/#{others_key.key}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for an unknown key" do
      delete "/api/v1/account/api-keys/ak_missing", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      get "/api/v1/account/api-keys"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "scope enforcement" do
    let(:key) { user.api_keys.create!(name: "Scoped", scopes: [ApiKey::SCOPE_READ]) }
    let(:key_headers) { { "Authorization" => "Bearer #{key.raw_token}" } }

    it "allows safe (GET) requests with a read-only key" do
      get "/api/v1/account/api-keys", headers: key_headers
      expect(response).to have_http_status(:ok)
    end

    it "blocks mutating requests with a read-only key" do
      post "/api/v1/account/api-keys", params: { name: "Nope" }, headers: key_headers
      expect(response).to have_http_status(:forbidden)
    end

    it "allows mutating requests with a write-scoped key" do
      writer = user.api_keys.create!(name: "Writer", scopes: [ApiKey::SCOPE_READ, ApiKey::SCOPE_WRITE])
      post "/api/v1/account/api-keys", params: { name: "OK" },
           headers: { "Authorization" => "Bearer #{writer.raw_token}" }
      expect(response).to have_http_status(:created)
    end

    it "treats a scopeless (legacy) key as full access" do
      legacy = user.api_keys.create!(name: "Legacy")
      post "/api/v1/account/api-keys", params: { name: "OK" },
           headers: { "Authorization" => "Bearer #{legacy.raw_token}" }
      expect(response).to have_http_status(:created)
    end

    it "rejects unknown scope values at creation" do
      post "/api/v1/account/api-keys", params: { name: "Bad", scopes: ["admin"] }, headers: headers
      # Unknown scopes are filtered out, so the key is created with no scopes.
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["api_key"]["scopes"]).to eq([])
    end

    # Impact check: the guard lives in BaseController, so it must apply to EVERY
    # org-scoped endpoint, not just /account/api-keys. Probe an unrelated one.
    context "across other controllers (BaseController guard is global)" do
      let(:org) { create(:organization, owner: user, domain: "scope.com") }
      let!(:membership) { create(:membership, user: user, organization: org, role: Membership::ROLE_OWNER, status: Membership::STATUS_ACTIVE) }

      it "allows a read-only key to GET org-scoped resources" do
        get "/api/v1/orgs/#{org.key}/tags", headers: key_headers
        expect(response).to have_http_status(:ok)
      end

      it "blocks a read-only key from mutating an unrelated org-scoped resource" do
        post "/api/v1/orgs/#{org.key}/tags", params: { name: "blocked" }, headers: key_headers
        expect(response).to have_http_status(:forbidden)
        expect(org.tags.count).to eq(0)
      end

      it "still lets session (web) auth mutate — keyless requests are unaffected" do
        post "/api/v1/orgs/#{org.key}/tags", params: { name: "ok" }, headers: auth_headers(user)
        expect(response).to have_http_status(:created)
      end
    end
  end
end
