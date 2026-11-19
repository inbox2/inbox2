require "rails_helper"

# Sender avatars: Gravatar → domain icon → 404 (client draws initials).
RSpec.describe "Api::V1::Avatars", type: :request do
  let(:user) { create(:user, username: "avataruser") }
  let(:headers) { auth_headers(user) }
  let(:png) do
    Net::HTTPOK.new("1.1", "200", "OK").tap do |r|
      r["Content-Type"] = "image/png"
      allow(r).to receive(:body).and_return("\x89PNG")
    end
  end

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(PrivateAddressGuard).to receive(:resolve).and_return(["93.184.216.34"])
    allow_any_instance_of(Api::V1::AvatarsController).to receive(:perform_get).and_return(png)
  end

  it "serves the Gravatar when the address has one" do
    allow_any_instance_of(AvatarResolver).to receive(:exists?).and_return(true)
    get "/api/v1/avatars", params: { email: "Sam@Example.com" }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/png")
    sha = Digest::SHA256.hexdigest("sam@example.com")
    expect(AvatarResolver.lookup("sam@example.com")).to start_with("https://www.gravatar.com/avatar/#{sha}")
  end

  it "falls back to the sender domain's icon" do
    allow_any_instance_of(AvatarResolver).to receive(:exists?).and_return(false)
    allow(BrandFetcher).to receive(:lookup).with("acme.com").and_return(
      BrandFetcher::Brand.new(domain: "acme.com", icon_url: BrandFetcher.proxy_url("https://acme.com/icon.png"))
    )

    expect(AvatarResolver.lookup("sam@acme.com")).to eq("https://acme.com/icon.png")
    get "/api/v1/avatars", params: { email: "sam@acme.com" }, headers: headers
    expect(response).to have_http_status(:ok)
  end

  it "uses Google's favicon for the domain when there is no Gravatar" do
    allow_any_instance_of(AvatarResolver).to receive(:exists?) { |_, url| url.include?("gstatic.com") }
    expect(AvatarResolver.lookup("security-noreply@linkedin.com"))
      .to start_with("https://t1.gstatic.com/faviconV2?").and include("url=https%3A%2F%2Flinkedin.com")
  end

  it "never asks Google about a freemail domain" do
    asked = []
    allow_any_instance_of(AvatarResolver).to receive(:exists?) { |_, url| asked << url; false }
    expect(AvatarResolver.lookup("sam@gmail.com")).to be_nil
    expect(asked).to all(include("gravatar.com"))
  end

  it "404s when nothing is found (freemail without a Gravatar)" do
    allow_any_instance_of(AvatarResolver).to receive(:exists?).and_return(false)
    get "/api/v1/avatars", params: { email: "sam@gmail.com" }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "404s on a malformed address without any lookup" do
    expect_any_instance_of(AvatarResolver).not_to receive(:exists?)
    get "/api/v1/avatars", params: { email: "not-an-address" }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "404s an SVG icon, which the phones can't decode" do
    svg = Net::HTTPOK.new("1.1", "200", "OK").tap do |r|
      r["Content-Type"] = "image/svg+xml"
      allow(r).to receive(:body).and_return("<svg/>")
    end
    allow_any_instance_of(Api::V1::AvatarsController).to receive(:perform_get).and_return(svg)
    allow_any_instance_of(AvatarResolver).to receive(:exists?).and_return(true)
    get "/api/v1/avatars", params: { email: "sam@acme.com" }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "requires authentication" do
    get "/api/v1/avatars", params: { email: "sam@acme.com" }
    expect(response).to have_http_status(:unauthorized)
  end
end
