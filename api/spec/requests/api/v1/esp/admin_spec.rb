require "rails_helper"

# E1 mapping: spec 21.2 — ESP, console side (docs/ESP.md)
RSpec.describe "ESP console API", type: :request do
  let(:org) { create(:organization, plan: Plan.paid) }
  let(:headers) { auth_headers(org.owner) }
  let(:base) { "/api/v1/orgs/#{org.key}/esp" }

  before { create(:membership, organization: org, user: org.owner, role: Membership::ROLE_OWNER) unless org.memberships.exists?(user: org.owner) }

  it "creates a sending key, shows the token once, and revokes it (21.2.1)" do
    post "#{base}/keys", params: { name: "Billing app" }, headers: headers
    expect(response).to have_http_status(:created)
    token = response.parsed_body["token"]
    expect(token).to start_with("isk_")
    expect(Esp::Key.authenticate(token)).to be_present

    get "#{base}/keys", headers: headers
    listed = response.parsed_body["keys"]
    expect(listed.first.keys).not_to include("token", "token_digest")

    delete "#{base}/keys/#{listed.first['id']}", headers: headers
    expect(response).to have_http_status(:no_content)
    expect(Esp::Key.authenticate(token)).to be_nil
  end

  it "is for admins only (21.2.2)" do
    member = create(:user)
    create(:membership, organization: org, user: member, role: Membership::ROLE_MEMBER)
    post "#{base}/keys", params: { name: "x" }, headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end

  it "hides another organization's ESP (E3)" do
    get "#{base}/keys", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:not_found)
  end

  it "adds a send-only domain with its DNS records and verifies it by the DKIM CNAME (21.2.3)" do
    post "#{base}/domains", params: { domain: "Mail.App.example" }, headers: headers
    expect(response).to have_http_status(:created)
    domain = response.parsed_body["domain"]
    expect(domain["name"]).to eq("mail.app.example")
    expect(domain["status"]).to eq("pending_dns")
    expect(domain["records"].map { |r| r["type"] }).to eq(%w[CNAME TXT])

    dkim = domain["records"].first
    resolver = instance_double(DnsResolver, cname: dkim["value"], txt: [])
    allow(DnsResolver).to receive(:new).and_return(resolver)
    post "#{base}/domains/#{domain['id']}/verify", headers: headers
    expect(response.parsed_body["domain"]["status"]).to eq("verified")
  end

  it "refuses a send-only domain that is already hosted (21.2.3)" do
    create(:domain, name: "hosted.test")
    post "#{base}/domains", params: { domain: "hosted.test" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "shows the send log and the month's usage (21.2.4)" do
    message = create(:esp_message, organization: org)
    create(:esp_delivery, message: message)
    create(:esp_message)

    get "#{base}/emails", headers: headers
    expect(response.parsed_body["emails"].map { |e| e["id"] }).to eq([message.key])

    get "#{base}/usage", headers: headers
    expect(response.parsed_body["usage"]).to include("allowance" => 10_000, "used" => 1)
  end
end
