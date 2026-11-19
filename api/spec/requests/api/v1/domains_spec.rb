require "rails_helper"

RSpec.describe "Api::V1::Domains", type: :request do
  let(:owner) { create(:user) }
  let(:org) { create(:organization, owner: owner) } # 1 primary domain (Free)
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "GET /index" do
    it "lists the org's domains" do
      create(:subscription, organization: org, plan: Plan.max)
      create(:domain, organization: org, name: "extra.test")
      get "/api/v1/orgs/#{org.key}/domains", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["domains"].map { |d| d["name"] }).to include(org.default_domain.name, "extra.test")
    end

    it "exposes a URL workspace slug per domain (parameterized name)" do
      create(:subscription, organization: org, plan: Plan.max)
      create(:domain, organization: org, name: "extra.test")
      get "/api/v1/orgs/#{org.key}/domains", headers: headers
      slugs = response.parsed_body["domains"].to_h { |d| [d["name"], d["slug"]] }
      expect(slugs["extra.test"]).to eq("extra-test")
    end
  end

  describe "POST /create" do
    it "adds a domain on a paid org" do
      create(:subscription, organization: org, plan: Plan.max)
      expect {
        post "/api/v1/orgs/#{org.key}/domains", params: { domain: "second.test" }, headers: headers
      }.to change { org.domains.count }.by(1)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["domain"]["name"]).to eq("second.test")
    end

    it "does not fetch a favicon for a later domain (it shows its initial)" do
      create(:subscription, organization: org, plan: Plan.max)
      ActiveJob::Base.queue_adapter = :test
      post "/api/v1/orgs/#{org.key}/domains", params: { domain: "second.test" }, headers: headers
      expect(FetchFaviconJob).not_to have_been_enqueued
    end

    it "403s when the domain quota is reached (Free = 1)" do
      post "/api/v1/orgs/#{org.key}/domains", params: { domain: "second.test" }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "422s a duplicate domain name" do
      create(:subscription, organization: org, plan: Plan.max)
      taken = create(:domain).name
      post "/api/v1/orgs/#{org.key}/domains", params: { domain: taken }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "403s a non-admin member" do
      member = create(:user)
      create(:membership, user: member, organization: org, role: "member", status: "active")
      post "/api/v1/orgs/#{org.key}/domains", params: { domain: "x.test" }, headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s for an org the user is not a member of (E3)" do
      other = create(:organization)
      post "/api/v1/orgs/#{other.key}/domains", params: { domain: "x.test" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /destroy" do
    it "removes a non-primary domain" do
      create(:subscription, organization: org, plan: Plan.max)
      d = create(:domain, organization: org, name: "drop.test")
      expect {
        delete "/api/v1/orgs/#{org.key}/domains/#{d.key}", headers: headers
      }.to change { org.domains.count }.by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "removes any domain (all equal) and re-derives the default to the next-oldest" do
      create(:subscription, organization: org, plan: Plan.max)
      oldest = org.default_domain
      newer = create(:domain, organization: org, name: "other.test")
      delete "/api/v1/orgs/#{org.key}/domains/#{oldest.key}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Organization.find(org.id).default_domain).to eq(newer)
    end
  end

  describe "per-domain icon" do
    it "serializes icon_url as nil when unset and a brand URL when set" do
      d = org.default_domain
      get "/api/v1/orgs/#{org.key}/domains/#{d.key}", headers: headers
      expect(response.parsed_body["domain"]).to have_key("icon_url")
      expect(response.parsed_body["domain"]["icon_url"]).to be_nil

      d.update!(icon_url: "orgs/#{org.key}/icons/abc.png")
      get "/api/v1/orgs/#{org.key}/domains/#{d.key}", headers: headers
      expect(response.parsed_body["domain"]["icon_url"]).to end_with("/orgs/#{org.key}/domains/#{d.key}/brand/icon")
    end

    it "422s an icon upload with no file" do
      d = org.default_domain
      post "/api/v1/orgs/#{org.key}/domains/#{d.key}/icon", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "403s an icon upload from a non-admin member" do
      member = create(:user)
      create(:membership, user: member, organization: org, role: "member", status: "active")
      d = org.default_domain
      post "/api/v1/orgs/#{org.key}/domains/#{d.key}/icon", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end

    it "streams the brand icon publicly (no auth) — 404 when unset" do
      d = org.default_domain
      get "/api/v1/orgs/#{org.key}/domains/#{d.key}/brand/icon" # no headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /dns and POST /dns/verify" do
    before { allow_any_instance_of(DnsResolver).to receive(:ns).and_return([]) }

    it "returns records and verifies a domain" do
      d = org.default_domain
      get "/api/v1/orgs/#{org.key}/domains/#{d.key}/dns", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["records"].map { |r| r["type"] }).to include("MX", "TXT", "CNAME")

      allow(DnsChecker).to receive(:new).and_return(
        instance_double(DnsChecker, call: { mx_ok: true, all_ok: true, checks: { mx: true, spf: true, dmarc: true, dkim: true } })
      )
      post "/api/v1/orgs/#{org.key}/domains/#{d.key}/dns/verify", headers: headers
      expect(response.parsed_body["verified"]).to be(true)
      expect(d.reload.status).to eq("verified")
    end

    it "detects the Cloudflare provider from the nameservers" do
      allow_any_instance_of(DnsResolver).to receive(:ns).and_return(%w[ariadne.ns.cloudflare.com viddy.ns.cloudflare.com])
      get "/api/v1/orgs/#{org.key}/domains/#{org.default_domain.key}/dns", headers: headers
      expect(response.parsed_body["provider"]).to eq("cloudflare")
    end

    it "reports no provider for a non-Cloudflare domain" do
      allow_any_instance_of(DnsResolver).to receive(:ns).and_return(%w[ns1.registrar.example])
      get "/api/v1/orgs/#{org.key}/domains/#{org.default_domain.key}/dns", headers: headers
      expect(response.parsed_body["provider"]).to be_nil
    end
  end

  describe "POST /dns/cloudflare" do
    let(:d) { org.default_domain }
    let(:applied) { { zone: d.name, records: [{ name: d.name, type: "MX", action: "created" }] } }
    let(:green) { { mx_ok: true, all_ok: true, checks: { mx: true, spf: true, dmarc: true, dkim: true } } }

    it "writes the records via the token and re-verifies (A3.6)" do
      allow_any_instance_of(CloudflareDns).to receive(:apply).and_return(applied)
      allow(DnsChecker).to receive(:new).and_return(instance_double(DnsChecker, call: green))

      post "/api/v1/orgs/#{org.key}/domains/#{d.key}/dns/cloudflare", params: { token: "cf-token" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["verified"]).to be(true)
      expect(response.parsed_body.dig("applied", "zone")).to eq(d.name)
      expect(d.reload.status).to eq("verified")
    end

    it "422s when no token is provided" do
      post "/api/v1/orgs/#{org.key}/domains/#{d.key}/dns/cloudflare", params: {}, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "422s with the Cloudflare error message when the API rejects the token" do
      allow_any_instance_of(CloudflareDns).to receive(:apply).and_raise(CloudflareDns::Error, "Cloudflare rejected the token")
      post "/api/v1/orgs/#{org.key}/domains/#{d.key}/dns/cloudflare", params: { token: "bad" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"].first["message"]).to match(/Cloudflare rejected/)
    end

    it "403s a non-admin member" do
      member = create(:user)
      create(:membership, user: member, organization: org, role: "member", status: "active")
      post "/api/v1/orgs/#{org.key}/domains/#{d.key}/dns/cloudflare", params: { token: "x" }, headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s for an org the user is not a member of (E3)" do
      other = create(:organization)
      post "/api/v1/orgs/#{other.key}/domains/#{other.default_domain.key}/dns/cloudflare", params: { token: "x" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
