require "rails_helper"

# Minimal fake resolver — no network.
FakeTrackingResolver = Struct.new(:cname_val, :a_vals) do
  def cname(_) = cname_val
  def a(_) = a_vals || []
end

RSpec.describe TrackingDns do
  let(:org) { create(:organization, with_default_domain: false) }
  let(:domain) { create(:domain, organization: org, name: "tuli.com") }

  it "is ok with no custom tracking host (uses the inbox2 default)" do
    result = described_class.new(domain).call
    expect(result[:ok]).to be(true)
  end

  it "verifies a DNS-only CNAME pointing at the inbox2 tracking host" do
    domain.update!(tracking_domain: "track.tuli.com")
    result = described_class.new(domain, resolver: FakeTrackingResolver.new(TrackingDns::TARGET, [])).call
    expect(result[:ok]).to be(true)
    expect(result[:proxied]).to be(false)
  end

  it "flags a Cloudflare-proxied (orange-cloud) record and tells the user to go DNS-only" do
    domain.update!(tracking_domain: "track.tuli.com")
    # No CNAME resolves (proxied), A record is a Cloudflare edge IP.
    result = described_class.new(domain, resolver: FakeTrackingResolver.new(nil, ["104.16.5.5"])).call
    expect(result[:ok]).to be(false)
    expect(result[:proxied]).to be(true)
    expect(result[:error]).to match(/DNS-only|grey cloud/i)
  end

  it "reports not-yet-resolving when the CNAME is absent and not proxied" do
    domain.update!(tracking_domain: "track.tuli.com")
    result = described_class.new(domain, resolver: FakeTrackingResolver.new(nil, ["198.51.100.4"])).call
    expect(result[:ok]).to be(false)
    expect(result[:proxied]).to be(false)
    expect(result[:error]).to match(/does not yet resolve/i)
  end
end

RSpec.describe "Domain open-tracking settings", type: :request do
  let(:owner) { create(:user) }
  let(:org) { create(:organization, owner: owner) }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:domain) { org.default_domain }
  let(:headers) { auth_headers(owner) }

  it "enables open tracking and sets a custom tracking host" do
    patch "/api/v1/orgs/#{org.key}/domains/#{domain.key}/tracking",
          params: { open_tracking_enabled: true, tracking_domain: "Track.Tuli.com" }, headers: headers

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["open_tracking_enabled"]).to be(true)
    expect(body["tracking_domain"]).to eq("track.tuli.com")
    expect(body["records"].first).to include("type" => "CNAME", "value" => Tracking::DEFAULT_HOST, "proxied" => false)
    expect(domain.reload.open_tracking_enabled).to be(true)
  end

  it "marks a custom host verified once its CNAME resolves (CF-for-SaaS off in test)" do
    domain.update!(tracking_domain: "track.tuli.com")
    allow(DnsResolver).to receive(:new).and_return(FakeTrackingResolver.new(TrackingDns::TARGET, []))

    post "/api/v1/orgs/#{org.key}/domains/#{domain.key}/tracking/verify", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["verified"]).to be(true)
    expect(domain.reload.tracking_domain_verified_at).to be_present
  end

  it "403s a non-admin member" do
    member = create(:user)
    create(:membership, user: member, organization: org, role: "member", status: "active")
    patch "/api/v1/orgs/#{org.key}/domains/#{domain.key}/tracking",
          params: { open_tracking_enabled: true }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end
end

RSpec.describe "Per-channel custom tracking host", type: :request do
  it "registers a custom host and returns the DNS-only CNAME to the inbox2 target" do
    post "/api/v1/tracking/register", params: { host: "Track.Tuli.com" }, headers: auth_headers(create(:user)), as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body["host"]).to eq("track.tuli.com")
    expect(body["cname_target"]).to eq(Tracking::DEFAULT_HOST)
    expect(body["records"].first).to include("type" => "CNAME", "value" => Tracking::DEFAULT_HOST, "proxied" => false)
  end

  it "422s a blank host" do
    post "/api/v1/tracking/register", params: { host: "" }, headers: auth_headers(create(:user)), as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "verifies a host once its DNS-only CNAME resolves (CF-for-SaaS off in test)" do
    allow(DnsResolver).to receive(:new).and_return(FakeTrackingResolver.new(TrackingDns::TARGET, []))
    post "/api/v1/tracking/verify-host", params: { host: "track.tuli.com" }, headers: auth_headers(create(:user)), as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["verified"]).to be(true)
  end
end
