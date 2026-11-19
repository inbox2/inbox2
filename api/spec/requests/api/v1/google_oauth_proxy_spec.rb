require "rails_helper"

# Stateless Google OAuth proxy — exchanges codes/refresh tokens server-side.
# E1 mapping: A1.10 (SSO Google/Microsoft) — server-side OAuth token proxy
RSpec.describe "Api::V1::GoogleOauthProxy", type: :request do
  let(:valid_redirect) { "http://localhost:3000/oauth-callback" }

  before do
    allow_any_instance_of(Api::V1::GoogleOauthProxyController)
      .to receive(:client_id).and_return("test-client-id")
    allow_any_instance_of(Api::V1::GoogleOauthProxyController)
      .to receive(:client_secret).and_return("test-secret")
  end

  def http_success(body)
    Net::HTTPOK.new("1.1", "200", "OK").tap { |r| allow(r).to receive(:body).and_return(body) }
  end

  def http_failure(body = "invalid_grant")
    Net::HTTPBadRequest.new("1.1", "400", "Bad Request").tap { |r| allow(r).to receive(:body).and_return(body) }
  end

  def http_upstream_outage(body = "upstream down")
    Net::HTTPServiceUnavailable.new("1.1", "503", "Service Unavailable").tap { |r| allow(r).to receive(:body).and_return(body) }
  end

  describe "GET /api/v1/auth/google/authorize" do
    context "positive" do
      it "returns an auth URL and a generated state" do
        get "/api/v1/auth/google/authorize", params: { redirect_uri: valid_redirect }
        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["auth_url"]).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")
        expect(body["auth_url"]).to include("client_id=test-client-id")
        expect(body["state"]).to be_present
      end

      it "echoes a caller-provided state" do
        get "/api/v1/auth/google/authorize", params: { redirect_uri: valid_redirect, state: "abc123" }
        expect(response.parsed_body["state"]).to eq("abc123")
      end

      it "passes login_hint through so a reconnect preselects the account" do
        get "/api/v1/auth/google/authorize",
            params: { redirect_uri: valid_redirect, login_hint: "user@gmail.com" }
        expect(response.parsed_body["auth_url"]).to include("login_hint=user%40gmail.com")
      end

      it "omits login_hint when not given" do
        get "/api/v1/auth/google/authorize", params: { redirect_uri: valid_redirect }
        expect(response.parsed_body["auth_url"]).not_to include("login_hint")
      end

      it "forwards the PKCE code_challenge, defaulting the method to S256" do
        get "/api/v1/auth/google/authorize",
            params: { redirect_uri: valid_redirect, code_challenge: "chal123" }
        url = response.parsed_body["auth_url"]
        expect(url).to include("code_challenge=chal123")
        expect(url).to include("code_challenge_method=S256")
      end

      it "honors an explicit code_challenge_method" do
        get "/api/v1/auth/google/authorize",
            params: { redirect_uri: valid_redirect, code_challenge: "chal123", code_challenge_method: "plain" }
        expect(response.parsed_body["auth_url"]).to include("code_challenge_method=plain")
      end

      it "omits the PKCE params when no challenge is given" do
        get "/api/v1/auth/google/authorize", params: { redirect_uri: valid_redirect }
        expect(response.parsed_body["auth_url"]).not_to include("code_challenge")
      end
    end

    context "negative" do
      it "returns 422 for a disallowed redirect_uri" do
        get "/api/v1/auth/google/authorize", params: { redirect_uri: "https://evil.com/oauth-callback" }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 400 when redirect_uri is missing" do
        get "/api/v1/auth/google/authorize"
        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  describe "POST /api/v1/auth/google/token" do
    context "positive" do
      it "returns the Google token response verbatim" do
        allow_any_instance_of(Api::V1::GoogleOauthProxyController)
          .to receive(:token_request).and_return(http_success('{"access_token":"at","refresh_token":"rt"}'))

        post "/api/v1/auth/google/token", params: { code: "auth_code", redirect_uri: valid_redirect }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["access_token"]).to eq("at")
        expect(response.parsed_body["refresh_token"]).to eq("rt")
      end

      it "forwards the PKCE code_verifier into the token request" do
        captured = nil
        allow_any_instance_of(Api::V1::GoogleOauthProxyController)
          .to receive(:token_request) { |_instance, form| captured = form; http_success('{"access_token":"at"}') }

        post "/api/v1/auth/google/token",
             params: { code: "auth_code", redirect_uri: valid_redirect, code_verifier: "ver123" }
        expect(response).to have_http_status(:ok)
        expect(captured[:code_verifier]).to eq("ver123")
      end

      it "omits code_verifier from the token request when not given" do
        captured = nil
        allow_any_instance_of(Api::V1::GoogleOauthProxyController)
          .to receive(:token_request) { |_instance, form| captured = form; http_success('{"access_token":"at"}') }

        post "/api/v1/auth/google/token", params: { code: "auth_code", redirect_uri: valid_redirect }
        expect(response).to have_http_status(:ok)
        expect(captured).not_to have_key(:code_verifier)
      end
    end

    context "negative" do
      it "returns 422 for a disallowed redirect_uri" do
        post "/api/v1/auth/google/token", params: { code: "auth_code", redirect_uri: "https://evil.com/oauth-callback" }
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 400 when code is missing" do
        post "/api/v1/auth/google/token", params: { redirect_uri: valid_redirect }
        expect(response).to have_http_status(:bad_request)
      end

      it "passes Google's 4xx through when it rejects the exchange" do
        allow_any_instance_of(Api::V1::GoogleOauthProxyController)
          .to receive(:token_request).and_return(http_failure)

        post "/api/v1/auth/google/token", params: { code: "bad_code", redirect_uri: valid_redirect }
        expect(response).to have_http_status(:bad_request)
      end

      it "returns 502 when Google itself is down (5xx)" do
        allow_any_instance_of(Api::V1::GoogleOauthProxyController)
          .to receive(:token_request).and_return(http_upstream_outage)

        post "/api/v1/auth/google/token", params: { code: "auth_code", redirect_uri: valid_redirect }
        expect(response).to have_http_status(:bad_gateway)
      end
    end
  end

  describe "POST /api/v1/auth/google/refresh" do
    context "positive" do
      it "returns the refreshed token response" do
        allow_any_instance_of(Api::V1::GoogleOauthProxyController)
          .to receive(:token_request).and_return(http_success('{"access_token":"new_at"}'))

        post "/api/v1/auth/google/refresh", params: { refresh_token: "rt" }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["access_token"]).to eq("new_at")
      end
    end

    context "negative" do
      it "returns 400 when refresh_token is missing" do
        post "/api/v1/auth/google/refresh"
        expect(response).to have_http_status(:bad_request)
      end

      it "passes Google's 4xx through when it rejects the refresh (revoked token)" do
        # The sync engine must see the 4xx to flag the account needs_reauth —
        # a blanket 502 looked like a transient proxy outage and never
        # prompted re-auth.
        allow_any_instance_of(Api::V1::GoogleOauthProxyController)
          .to receive(:token_request).and_return(http_failure)

        post "/api/v1/auth/google/refresh", params: { refresh_token: "stale" }
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.to_s).to include("invalid_grant")
      end

      it "returns 502 when Google itself is down (5xx)" do
        allow_any_instance_of(Api::V1::GoogleOauthProxyController)
          .to receive(:token_request).and_return(http_upstream_outage)

        post "/api/v1/auth/google/refresh", params: { refresh_token: "rt" }
        expect(response).to have_http_status(:bad_gateway)
      end
    end
  end
end
