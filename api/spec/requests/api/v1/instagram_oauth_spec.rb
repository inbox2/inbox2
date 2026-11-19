require "rails_helper"

# Instagram-Login OAuth redirect bounce (unauthenticated; just forwards the auth
# code to the desktop's local loopback). See docs/Meta-Setup.md (Instagram).
RSpec.describe "Api::V1::InstagramOauth", type: :request do
  describe "GET /api/v1/oauth/instagram/callback" do
    it "302s the code back to the local loopback port carried in state" do
      get "/api/v1/oauth/instagram/callback", params: { code: "AUTH_CODE", state: "csrf123.8723" }
      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq(
        "http://localhost:8723/oauth-callback?code=AUTH_CODE&state=csrf123"
      )
    end

    it "URL-encodes the code and forwards only the csrf (not the port)" do
      get "/api/v1/oauth/instagram/callback", params: { code: "a b/c", state: "tok.8724" }
      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to eq(
        "http://localhost:8724/oauth-callback?code=a+b%2Fc&state=tok"
      )
    end

    it "rejects a port outside the registered loopback range" do
      get "/api/v1/oauth/instagram/callback", params: { code: "AUTH_CODE", state: "csrf.9999" }
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a missing code" do
      get "/api/v1/oauth/instagram/callback", params: { state: "csrf.8723" }
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a malformed state (no port)" do
      get "/api/v1/oauth/instagram/callback", params: { code: "AUTH_CODE", state: "csrfonly" }
      expect(response).to have_http_status(:bad_request)
    end
  end
end
