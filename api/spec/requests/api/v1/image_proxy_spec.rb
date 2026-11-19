require "rails_helper"

# Image proxy — server-side fetch of remote email images (privacy / tracking-pixel
# defence). E1 mapping: spec 4.1.2 — safe HTML rendering with image proxying.
RSpec.describe "Api::V1::ImageProxy", type: :request do
  let(:user) { create(:user, username: "proxyuser") }
  let(:headers) { auth_headers(user) }
  let(:remote) { "https://cdn.example.com/pixel.png" }

  # No DNS in the test env: make the public test host resolve to a public IP,
  # while real literal-IP handling (the SSRF cases) still runs through.
  before do
    allow(PrivateAddressGuard).to receive(:resolve).and_wrap_original do |orig, host|
      host == "cdn.example.com" ? ["93.184.216.34"] : orig.call(host)
    end
  end

  def http_ok(content_type:, body: "\x89PNG\r\n", content_length: nil)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |r|
      r["Content-Type"] = content_type
      r["Content-Length"] = content_length.to_s if content_length
      allow(r).to receive(:body).and_return(body)
    end
  end

  def http_redirect(location)
    Net::HTTPFound.new("1.1", "302", "Found").tap { |r| r["Location"] = location }
  end

  def stub_fetch(response)
    allow_any_instance_of(Api::V1::ImageProxyController).to receive(:perform_get).and_return(response)
  end

  describe "GET /api/v1/image-proxy" do
    context "positive" do
      it "proxies an image and returns the bytes with the upstream content type" do
        stub_fetch(http_ok(content_type: "image/png"))
        get "/api/v1/image-proxy", params: { url: remote }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("image/png")
        expect(response.body).to eq("\x89PNG\r\n")
      end

      it "authenticates with a personal API key (ink_ token) instead of a session" do
        api_key = user.api_keys.create!(name: "Desktop")
        stub_fetch(http_ok(content_type: "image/png"))
        get "/api/v1/image-proxy", params: { url: remote },
            headers: { "Authorization" => "Bearer #{api_key.raw_token}" }

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("image/png")
      end

      it "signs the upstream fetch with Web Bot Auth and the documented UA when a key is configured" do
        allow(WebBotAuth).to receive(:private_key).and_return(OpenSSL::PKey.generate_key("ED25519"))
        captured = nil
        allow_any_instance_of(Net::HTTP).to receive(:request) do |_, req|
          captured = req
          http_ok(content_type: "image/png")
        end

        get "/api/v1/image-proxy", params: { url: remote }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(captured["User-Agent"]).to eq("inbox2-image-proxy/1.0 (+https://inbox2.com/bot)")
        expect(captured["Signature-Input"]).to include('tag="web-bot-auth"')
        expect(captured["Signature"]).to match(/\Asig1=:.+:\z/)
        expect(captured["Signature-Agent"]).to eq(%("#{WebBotAuth.agent}"))
      end

      it "sends no signature headers when Web Bot Auth is not configured" do
        allow(WebBotAuth).to receive(:private_key).and_return(nil)
        captured = nil
        allow_any_instance_of(Net::HTTP).to receive(:request) do |_, req|
          captured = req
          http_ok(content_type: "image/png")
        end

        get "/api/v1/image-proxy", params: { url: remote }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(captured["Signature-Input"]).to be_nil
        expect(captured["Signature"]).to be_nil
      end

      it "follows a redirect to a public URL" do
        controller = Api::V1::ImageProxyController
        allow_any_instance_of(controller).to receive(:perform_get)
          .and_return(http_redirect("https://cdn.example.com/real.png"), http_ok(content_type: "image/gif"))

        get "/api/v1/image-proxy", params: { url: remote }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("image/gif")
      end
    end

    context "negative" do
      it "requires authentication" do
        get "/api/v1/image-proxy", params: { url: remote }
        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects an expired API key" do
        api_key = user.api_keys.create!(name: "Old", expires_at: 1.day.ago)
        get "/api/v1/image-proxy", params: { url: remote },
            headers: { "Authorization" => "Bearer #{api_key.raw_token}" }
        expect(response).to have_http_status(:unauthorized)
      end

      it "returns 400 when url is missing" do
        get "/api/v1/image-proxy", headers: headers
        expect(response).to have_http_status(:bad_request)
      end

      it "returns 422 for a private/loopback target (SSRF)" do
        get "/api/v1/image-proxy", params: { url: "http://127.0.0.1/secret.png" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 422 for a link-local cloud-metadata target (SSRF)" do
        get "/api/v1/image-proxy", params: { url: "http://169.254.169.254/latest/meta-data/" }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 422 when a redirect points at a private address" do
        stub_fetch(http_redirect("http://10.0.0.5/internal.png"))
        get "/api/v1/image-proxy", params: { url: remote }, headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 415 when the upstream content type is not an image" do
        stub_fetch(http_ok(content_type: "text/html"))
        get "/api/v1/image-proxy", params: { url: remote }, headers: headers
        expect(response).to have_http_status(:unsupported_media_type)
      end

      it "returns 413 when the upstream Content-Length exceeds the cap" do
        stub_fetch(http_ok(content_type: "image/png", content_length: 20 * 1024 * 1024))
        get "/api/v1/image-proxy", params: { url: remote }, headers: headers
        expect(response).to have_http_status(:content_too_large)
      end

      it "gives up once the whole fetch is out of time" do
        stub_const("Api::V1::ImageProxyController::TOTAL_TIMEOUT", 0.05)
        allow_any_instance_of(Api::V1::ImageProxyController).to receive(:perform_get) { sleep 1 }
        get "/api/v1/image-proxy", params: { url: remote }, headers: headers
        expect(response).to have_http_status(:bad_gateway)
      end

      it "returns 502 when the upstream connection fails" do
        allow_any_instance_of(Api::V1::ImageProxyController).to receive(:perform_get).and_raise(SocketError)
        get "/api/v1/image-proxy", params: { url: remote }, headers: headers
        expect(response).to have_http_status(:bad_gateway)
      end
    end
  end
end
