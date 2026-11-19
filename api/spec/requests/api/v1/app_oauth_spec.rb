require "rails_helper"

# Brokered provider OAuth for a registered application (docs/App-OAuth.md):
# authorize (app server, API key) → consent/start (browser) → provider callback
# → token (app server, API key, single use).
RSpec.describe "Api::V1::AppOauth", type: :request do
  let(:user) { create(:user) }
  let(:org) { create(:organization, owner: user) }
  let(:headers) { auth_headers(user) }
  let(:redirect_uri) { "https://partner.example.com/callback" }
  let!(:registered) { create(:oauth_app, organization: org, name: "Partner CRM", redirect_uris: [redirect_uri]) }

  before do
    create(:membership, user: user, organization: org, role: "owner", status: "active")
    allow(OauthProvider).to receive(:client_id).and_return("test-client-id")
    allow(OauthProvider).to receive(:client_secret).and_return("test-secret")
  end

  def authorize!(params = {})
    post "/api/v1/auth/app-oauth/authorize",
         params: { app: registered.key, provider: "google", redirect_uri: redirect_uri }.merge(params),
         headers: headers
    response.parsed_body["flow"]
  end

  describe "POST /api/v1/auth/app-oauth/authorize" do
    context "positive" do
      it "opens a flow and returns the branded consent URL" do
        expect { authorize!(state: "app-csrf-123") }.to change(OauthGrant, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body["flow"]).to start_with("oag_")
        expect(body["authorize_url"]).to end_with("/oauth/consent?flow=#{body['flow']}")

        grant = OauthGrant.last
        expect(grant.oauth_app).to eq(registered)
        expect(grant.provider).to eq("google")
        expect(grant.client_state).to eq("app-csrf-123")
        expect(grant.status).to eq(OauthGrant::STATUS_PENDING)
      end

      it "resolves the application by its registered name as well as its id" do
        authorize!(app: "partner crm")
        expect(response).to have_http_status(:created)
        expect(OauthGrant.last.oauth_app).to eq(registered)
      end
    end

    context "negative" do
      it "rejects a redirect_uri that is not on the app's whitelist" do
        authorize!(redirect_uri: "https://attacker.example.com/steal")
        expect(response).to have_http_status(:unprocessable_content)
        expect(OauthGrant.count).to eq(0)
      end

      it "rejects an unsupported provider" do
        authorize!(provider: "yahoo")
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "404s on an application belonging to another org (E3)" do
        authorize!(app: create(:oauth_app).key)
        expect(response).to have_http_status(:not_found)
      end

      it "requires authentication" do
        post "/api/v1/auth/app-oauth/authorize",
             params: { app: registered.key, provider: "google", redirect_uri: redirect_uri }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "GET /api/v1/auth/app-oauth/consent" do
    it "describes the asking app + provider with no inbox2 session" do
      flow = authorize!

      get "/api/v1/auth/app-oauth/consent", params: { flow: flow }

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["app"]["name"]).to eq("Partner CRM")
      expect(body["provider"]).to eq("google")
      expect(body["provider_label"]).to eq("Google")
    end

    it "404s on an expired flow" do
      flow = authorize!
      OauthGrant.last.update!(expires_at: 1.minute.ago)
      get "/api/v1/auth/app-oauth/consent", params: { flow: flow }
      expect(response).to have_http_status(:not_found)
    end

    it "404s on an unknown flow" do
      get "/api/v1/auth/app-oauth/consent", params: { flow: "oag_nope" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/auth/app-oauth/start" do
    it "redirects to the provider and records the callback it used" do
      flow = authorize!

      get "/api/v1/auth/app-oauth/start", params: { flow: flow }

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
      expect(response.location).to include("state=#{flow}")
      expect(response.location).to include("access_type=offline")
      expect(OauthGrant.last.callback_uri).to end_with("/api/v1/auth/app-oauth/callback")
    end
  end

  describe "GET /api/v1/auth/app-oauth/cancel" do
    it "returns the user to the app with an explicit denial" do
      flow = authorize!(state: "app-csrf-123")
      get "/api/v1/auth/app-oauth/cancel", params: { flow: flow }

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("#{redirect_uri}?")
      expect(response.location).to include("error=access_denied")
      expect(response.location).to include("state=app-csrf-123")
    end
  end

  describe "GET /api/v1/auth/app-oauth/callback" do
    let(:tokens) do
      { "access_token" => "ya29.at", "refresh_token" => "1//rt", "expires_in" => 3599, "scope" => "gmail.modify" }
    end

    before do
      allow(OauthProvider).to receive(:exchange_code).and_return(tokens)
      allow(OauthProvider).to receive(:fetch_email).and_return("user@gmail.com")
    end

    it "exchanges the code and bounces the user back to the app" do
      flow = authorize!(state: "app-csrf-123")
      get "/api/v1/auth/app-oauth/start", params: { flow: flow }

      get "/api/v1/auth/app-oauth/callback", params: { code: "provider-code", state: flow }

      expect(response).to have_http_status(:found)
      expect(response.location).to include("flow=#{flow}")
      expect(response.location).to include("state=app-csrf-123")

      grant = OauthGrant.last
      expect(grant.status).to eq(OauthGrant::STATUS_AUTHORIZED)
      expect(grant.email).to eq("user@gmail.com")
      expect(grant.access_token).to eq("ya29.at")
    end

    it "passes a provider-side denial back to the app instead of erroring" do
      flow = authorize!
      get "/api/v1/auth/app-oauth/callback", params: { error: "access_denied", state: flow }

      expect(response).to have_http_status(:found)
      expect(response.location).to include("error=access_denied")
      expect(OauthGrant.last.status).to eq(OauthGrant::STATUS_PENDING)
    end

    it "returns the app an error when the provider rejects the exchange" do
      allow(OauthProvider).to receive(:exchange_code).and_raise(OauthProvider::Error, "boom")
      flow = authorize!
      get "/api/v1/auth/app-oauth/start", params: { flow: flow }

      get "/api/v1/auth/app-oauth/callback", params: { code: "provider-code", state: flow }

      expect(response).to have_http_status(:found)
      expect(response.location).to include("error=server_error")
    end

    it "rejects an unknown state (no grant to attach the code to)" do
      get "/api/v1/auth/app-oauth/callback", params: { code: "c", state: "oag_unknown" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST /api/v1/auth/app-oauth/token" do
    let(:flow) do
      f = authorize!(state: "app-csrf-123")
      get "/api/v1/auth/app-oauth/start", params: { flow: f }
      allow(OauthProvider).to receive(:exchange_code).and_return(
        { "access_token" => "ya29.at", "refresh_token" => "1//rt", "expires_in" => 3599, "scope" => "gmail.modify" }
      )
      allow(OauthProvider).to receive(:fetch_email).and_return("user@gmail.com")
      get "/api/v1/auth/app-oauth/callback", params: { code: "provider-code", state: f }
      f
    end

    context "positive" do
      it "hands the provider credential to the app once" do
        post "/api/v1/auth/app-oauth/token", params: { flow: flow }, headers: headers

        expect(response).to have_http_status(:ok)
        cred = response.parsed_body["credential"]
        expect(cred["provider"]).to eq("google")
        expect(cred["email"]).to eq("user@gmail.com")
        expect(cred["access_token"]).to eq("ya29.at")
        expect(cred["refresh_token"]).to eq("1//rt")
        expect(cred["state"]).to eq("app-csrf-123")
        expect(cred["expires_at"]).to be_present
      end

      it "wipes the tokens from the row on redemption" do
        post "/api/v1/auth/app-oauth/token", params: { flow: flow }, headers: headers
        grant = OauthGrant.last
        expect(grant.status).to eq(OauthGrant::STATUS_CONSUMED)
        expect(grant.access_token).to be_nil
        expect(grant.refresh_token).to be_nil
      end
    end

    context "negative" do
      it "refuses a second redemption" do
        post "/api/v1/auth/app-oauth/token", params: { flow: flow }, headers: headers
        post "/api/v1/auth/app-oauth/token", params: { flow: flow }, headers: headers
        expect(response).to have_http_status(:bad_request)
      end

      it "refuses a flow the provider has not answered yet" do
        pending_flow = authorize!
        post "/api/v1/auth/app-oauth/token", params: { flow: pending_flow }, headers: headers
        expect(response).to have_http_status(:bad_request)
      end

      it "refuses an expired redemption window" do
        f = flow
        OauthGrant.last.update!(expires_at: 1.minute.ago)
        post "/api/v1/auth/app-oauth/token", params: { flow: f }, headers: headers
        expect(response).to have_http_status(:bad_request)
      end

      it "404s for a caller outside the application's org (E3)" do
        f = flow
        outsider = create(:user)
        post "/api/v1/auth/app-oauth/token", params: { flow: f }, headers: auth_headers(outsider)
        expect(response).to have_http_status(:not_found)
      end

      it "requires authentication — the flow key alone is not a bearer" do
        f = flow
        post "/api/v1/auth/app-oauth/token", params: { flow: f }
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "POST /api/v1/auth/app-oauth/refresh" do
    it "refreshes against the web client and returns the provider's response" do
      allow(OauthProvider).to receive(:refresh_tokens)
        .with("google", "1//rt").and_return({ "access_token" => "ya29.fresh", "expires_in" => 3599 })

      post "/api/v1/auth/app-oauth/refresh",
           params: { provider: "google", refresh_token: "1//rt" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["access_token"]).to eq("ya29.fresh")
    end

    it "surfaces a provider rejection (revoked/expired refresh token)" do
      allow(OauthProvider).to receive(:refresh_tokens).and_raise(OauthProvider::Error, "invalid_grant")

      post "/api/v1/auth/app-oauth/refresh",
           params: { provider: "google", refresh_token: "dead" }, headers: headers

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an unsupported provider" do
      post "/api/v1/auth/app-oauth/refresh",
           params: { provider: "yahoo", refresh_token: "x" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "requires authentication" do
      post "/api/v1/auth/app-oauth/refresh", params: { provider: "google", refresh_token: "1//rt" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
