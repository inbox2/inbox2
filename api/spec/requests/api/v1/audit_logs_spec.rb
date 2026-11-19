require "rails_helper"

RSpec.describe "Api::V1::AuditLogs", type: :request do
  # E1 mapping: spec 11.3.2, A15.5 — Audit logs
  let(:owner) { create(:user, username: "auditowner") }
  let(:org) { create(:organization, owner: owner, domain: "audit.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/audit-log" do
    it "returns audit logs for admins" do
      create(:audit_log, organization: org, action: "member.invited", membership: membership)
      create(:audit_log, organization: org, action: "rule.created")

      get "/api/v1/orgs/#{org.key}/audit-log", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["audit_logs"].length).to eq(2)
      body["audit_logs"].each { |l| expect(l["id"]).to start_with("aud_") }
    end

    it "forbids regular members" do
      member = create(:user, username: "auditmember")
      create(:membership, user: member, organization: org, role: "member", status: "active")

      get "/api/v1/orgs/#{org.key}/audit-log", headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 404 for tenant isolation (E3)" do
      other_user = create(:user, username: "auditiso")
      other_org = create(:organization, owner: other_user, domain: "auditiso.com")
      create(:membership, user: other_user, organization: other_org, role: "owner", status: "active")

      get "/api/v1/orgs/#{other_org.key}/audit-log", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
