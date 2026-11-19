require "rails_helper"

RSpec.describe "Api::V1::MailFilters", type: :request do
  # E1 mapping: spec 11.1.4, A15.1 — Mail filters (allow/blocklist)
  let(:owner) { create(:user, username: "filterowner") }
  let(:org) { create(:organization, owner: owner, domain: "filters.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "GET /api/v1/orgs/:org_id/filters" do
    it "lists blocklist entries" do
      create(:mail_filter, organization: org, kind: "blocklist", value: "spam@evil.com")
      get "/api/v1/orgs/#{org.key}/filters", params: { kind: "blocklist" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["filters"].length).to eq(1)
    end

    it "lists allowlist entries" do
      create(:mail_filter, organization: org, kind: "allowlist", value: "trusted@good.com")
      get "/api/v1/orgs/#{org.key}/filters", params: { kind: "allowlist" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["filters"].length).to eq(1)
    end
  end

  describe "POST /api/v1/orgs/:org_id/filters" do
    it "adds a blocklist entry" do
      post "/api/v1/orgs/#{org.key}/filters",
           params: { kind: "blocklist", value: "blocked@evil.com" },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["filter"]["kind"]).to eq("blocklist")
    end

    it "adds a bare-domain entry" do
      post "/api/v1/orgs/#{org.key}/filters",
           params: { kind: "junk", value: "facebookmail.com" },
           headers: headers
      expect(response).to have_http_status(:created)
    end

    it "rejects a value that is neither an address nor a domain" do
      post "/api/v1/orgs/#{org.key}/filters",
           params: { kind: "junk", value: "wxsxsa" },
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects duplicate entry" do
      create(:mail_filter, organization: org, kind: "blocklist", value: "dup@evil.com")
      post "/api/v1/orgs/#{org.key}/filters",
           params: { kind: "blocklist", value: "dup@evil.com" },
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/filters/:id" do
    let!(:filter) { create(:mail_filter, organization: org) }

    it "removes a filter entry" do
      expect {
        delete "/api/v1/orgs/#{org.key}/filters/#{filter.key}", headers: headers
      }.to change(MailFilter, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "returns 404 for an unknown filter" do
      delete "/api/v1/orgs/#{org.key}/filters/mf_missing", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "mail filters — negative paths" do
    it "requires authentication" do
      get "/api/v1/orgs/#{org.key}/filters", params: { kind: "blocklist" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for an org the user is not a member of" do
      stranger = create(:user, username: "filterstranger")
      stranger_org = create(:organization, owner: stranger, domain: "fstranger.com")
      create(:membership, user: stranger, organization: stranger_org, role: "owner", status: "active")
      get "/api/v1/orgs/#{stranger_org.key}/filters", params: { kind: "blocklist" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
