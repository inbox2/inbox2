require "rails_helper"

RSpec.describe "Api::V1::Dns", type: :request do
  let(:owner) { create(:user, username: "dnsowner") }
  let(:org) { create(:organization, owner: owner, domain: "dns-test.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  # spec 2.3.2, A3.5
  describe "GET /api/v1/orgs/:org_id/dns" do
    it "returns required DNS records with status" do
      get "/api/v1/orgs/#{org.key}/dns", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["domain"]).to eq("dns-test.com")
      expect(body["records"]).to be_an(Array)
      expect(body["records"].length).to be >= 3
      types = body["records"].map { |r| r["type"] }
      expect(types).to include("MX", "TXT", "CNAME")
    end

    # DNS is domain setup — admin/owner only.
    it "forbids a regular member from viewing DNS records" do
      member = create(:user, username: "dnsmember")
      create(:membership, user: member, organization: org, role: "member", status: "active")

      get "/api/v1/orgs/#{org.key}/dns", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  # spec A3.6 — live DNS check (resolver stubbed so specs don't hit the network).
  describe "POST /api/v1/orgs/:org_id/dns/verify" do
    def stub_check(mx_ok)
      checks = { mx: mx_ok, spf: mx_ok, dmarc: mx_ok, dkim: mx_ok }
      allow(DnsChecker).to receive(:new).and_return(
        instance_double(DnsChecker, call: { mx_ok: mx_ok, all_ok: mx_ok, checks: checks })
      )
    end

    it "marks the domain verified when MX resolves correctly" do
      stub_check(true)
      post "/api/v1/orgs/#{org.key}/dns/verify", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["verified"]).to be(true)
      expect(response.parsed_body["checks"]).to include("mx" => true)
      expect(org.default_domain.reload.status).to eq("verified")
    end

    it "stays pending and returns failed checks when MX is missing" do
      stub_check(false)
      post "/api/v1/orgs/#{org.key}/dns/verify", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["verified"]).to be(false)
      expect(org.default_domain.reload.status).to eq("pending_dns")
    end

    it "persists the per-record check map for the admin health card" do
      stub_check(true)
      post "/api/v1/orgs/#{org.key}/dns/verify", headers: headers
      org.reload
      expect(org.default_domain.reload.dns_checks).to include("mx" => true, "spf" => true, "dmarc" => true, "dkim" => true)
      expect(org.default_domain.dns_checked_at).to be_present
    end

    it "records the per-record map but keeps a receiving-mail domain's status" do
      org.default_domain.update!(status: "receiving_mail")
      stub_check(false)
      post "/api/v1/orgs/#{org.key}/dns/verify", headers: headers
      org.reload
      expect(org.default_domain.status).to eq("receiving_mail")
      expect(org.default_domain.reload.dns_checks).to include("mx" => false)
    end
  end

  # spec A3.7
  describe "POST /api/v1/orgs/:org_id/dns/cloudflare" do
    it "configures Cloudflare DNS with token" do
      post "/api/v1/orgs/#{org.key}/dns/cloudflare",
           params: { api_token: "cf_test_token_123" },
           headers: headers
      expect(response).to have_http_status(:ok)
    end

    it "rejects missing API token" do
      post "/api/v1/orgs/#{org.key}/dns/cloudflare", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
