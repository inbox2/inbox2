require "rails_helper"

# Open-tracking pixel endpoint (docs/Open-Tracking.md).
RSpec.describe "GET /o/:token.gif", type: :request do
  let(:org) { create(:organization) }
  let(:conversation) { create(:conversation, organization: org) }
  let(:message) do
    create(:message, conversation: conversation, organization: org,
                     is_inbound: false, tracking_token: Tracking.token)
  end

  it "returns a 1x1 GIF and records an open correlated to the MX message" do
    expect {
      get "/o/#{message.tracking_token}.gif"
    }.to change(MessageOpen, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(response.content_type).to eq("image/gif")
    expect(response.body).to eq(Tracking::PIXEL_GIF)
    expect(response.headers["Cache-Control"]).to include("no-store")

    open = MessageOpen.last
    expect(open.token).to eq(message.tracking_token)
    expect(open.organization_id).to eq(org.id) # MX correlation
    expect(message.reload.opens).to include(open)
  end

  it "counts every render (never caches — no dedup on repeat opens)" do
    expect {
      get "/o/#{message.tracking_token}.gif"
      get "/o/#{message.tracking_token}.gif"
    }.to change(MessageOpen, :count).by(2)
  end

  it "flags a provider-proxy prefetch and excludes it from the real-open count" do
    get "/o/#{message.tracking_token}.gif",
        headers: { "User-Agent" => "Mozilla/5.0 (via ggpht.com GoogleImageProxy)" }

    open = MessageOpen.last
    expect(open.proxied).to be(true)
    expect(open.proxy_kind).to eq("gmail")
    expect(message.reload.opens.real).to be_empty
  end

  it "records the real client IP from CF-Connecting-IP across proxy forwards" do
    get "/o/#{message.tracking_token}.gif",
        headers: { "CF-Connecting-IP" => "203.0.113.7", "X-Forwarded-For" => "10.0.0.1" }

    expect(MessageOpen.last.ip).to eq("203.0.113.7")
  end

  it "still returns the GIF for an unknown token but records an org-less open" do
    expect {
      get "/o/localtok_unknown.gif" # e.g. a local-channel token the server can't map
    }.to change(MessageOpen, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(MessageOpen.last.organization_id).to be_nil
  end
end

RSpec.describe Tracking do
  it "injects the pixel before </body> and is idempotent" do
    token = "abc123"
    html = "<html><body><p>hi</p></body></html>"
    injected = described_class.inject(html, token, host: "o.inbox2.com")

    expect(injected).to include(%(src="https://o.inbox2.com/o/abc123.gif"))
    expect(injected).to match(%r{<img[^>]*/o/abc123\.gif[^>]*></body>})
    # Re-injecting the same token is a no-op (recompose/retry safe).
    expect(described_class.inject(injected, token, host: "o.inbox2.com")).to eq(injected)
  end

  it "appends the pixel when there is no </body>" do
    expect(described_class.inject("<p>hi</p>", "t")).to end_with(".gif\" width=\"1\" height=\"1\" alt=\"\" style=\"display:none;width:1px;height:1px;border:0\" />")
  end

  it "classifies a missing UA as a proxy prefetch" do
    expect(described_class.classify_proxy(nil)).to eq([true, "unknown"])
    expect(described_class.classify_proxy("Mozilla/5.0")).to eq([false, nil])
  end
end
