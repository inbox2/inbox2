require "rails_helper"

# TODO 46.10 — GET /orgs/:org/deliverability/auth-reports
RSpec.describe "Api::V1::Deliverability auth reports", type: :request do
  let(:owner) { create(:user, username: "arowner") }
  let(:org) { create(:organization, owner: owner, domain: "team.com") }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  let!(:clean) do
    org.mail_auth_reports.create!(kind: MailAuthReport::KIND_TLSRPT, reporter: "google.com",
                                  total_count: 10, failure_count: 0)
  end
  let!(:failing) do
    org.mail_auth_reports.create!(kind: MailAuthReport::KIND_DMARC, reporter: "yahoo.com",
                                  total_count: 8, failure_count: 2)
  end

  it "lists reports newest first with public IDs only (E5)" do
    get "/api/v1/orgs/#{org.key}/deliverability/auth-reports", headers: headers
    expect(response).to have_http_status(:ok)
    reports = response.parsed_body["auth_reports"]
    expect(reports.length).to eq(2)
    expect(reports.first["id"]).to start_with("mar_")
    expect(reports.map { |r| r["kind"] }).to contain_exactly("tlsrpt", "dmarc")
  end

  it "narrows to failures with failures_only" do
    get "/api/v1/orgs/#{org.key}/deliverability/auth-reports?failures_only=1", headers: headers
    reports = response.parsed_body["auth_reports"]
    expect(reports.length).to eq(1)
    expect(reports.first["reporter"]).to eq("yahoo.com")
  end

  it "forbids non-admin members" do
    member = create(:user, username: "armember")
    create(:membership, user: member, organization: org, role: "member", status: "active")
    get "/api/v1/orgs/#{org.key}/deliverability/auth-reports", headers: auth_headers(member)
    expect(response).to have_http_status(:forbidden)
  end

  it "404s cross-tenant (E3)" do
    outsider = create(:user, username: "aroutsider")
    other = create(:organization, owner: outsider, domain: "other.com")
    create(:membership, user: outsider, organization: other, role: "owner", status: "active")
    get "/api/v1/orgs/#{org.key}/deliverability/auth-reports", headers: auth_headers(outsider)
    expect(response).to have_http_status(:not_found)
  end
end
