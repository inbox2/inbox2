require "rails_helper"

RSpec.describe "Api::V1::Templates", type: :request do
  # E1 mapping: spec 8.2.1-8.2.2, A13.1 — Templates
  let(:owner) { create(:user, username: "tmplowner") }
  let(:org) { create(:organization, owner: owner, domain: "tmpls.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "POST /api/v1/orgs/:org_id/templates" do
    it "creates a template" do
      post "/api/v1/orgs/#{org.key}/templates",
           params: { name: "Welcome", body_html: "<p>Hello {{name}}</p>", scope: "shared" },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["template"]["name"]).to eq("Welcome")
      expect(response.parsed_body["template"]["scope"]).to eq("shared")
    end
  end

  describe "GET /api/v1/orgs/:org_id/templates" do
    it "lists templates" do
      Template.create!(organization: org, membership: membership, name: "Reply", body_html: "<p>Thanks</p>", scope: "personal")
      get "/api/v1/orgs/#{org.key}/templates", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["templates"].length).to eq(1)
    end
  end

  describe "POST /api/v1/orgs/:org_id/templates (negative)" do
    it "returns 422 when name is missing" do
      post "/api/v1/orgs/#{org.key}/templates", params: { body_html: "<p>x</p>", scope: "shared" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 for an invalid scope" do
      post "/api/v1/orgs/#{org.key}/templates", params: { name: "X", scope: "global" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "requires authentication" do
      post "/api/v1/orgs/#{org.key}/templates", params: { name: "X", scope: "shared" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/templates/:id" do
    let(:tmpl) { Template.create!(organization: org, membership: membership, name: "Old", body_html: "<p>t</p>", scope: "shared") }

    it "updates a template" do
      patch "/api/v1/orgs/#{org.key}/templates/#{tmpl.key}", params: { name: "New" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["template"]["name"]).to eq("New")
    end

    it "returns 422 for an invalid scope" do
      patch "/api/v1/orgs/#{org.key}/templates/#{tmpl.key}", params: { scope: "global" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 404 for an unknown template" do
      patch "/api/v1/orgs/#{org.key}/templates/tmpl_missing", params: { name: "X" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/templates/:id" do
    it "deletes a template" do
      tmpl = Template.create!(organization: org, membership: membership, name: "Bye", body_html: "<p>t</p>", scope: "shared")
      expect {
        delete "/api/v1/orgs/#{org.key}/templates/#{tmpl.key}", headers: headers
      }.to change(Template, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "returns 404 for an unknown template" do
      delete "/api/v1/orgs/#{org.key}/templates/tmpl_missing", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # Horizontal authorization: members may only mutate their own personal
  # templates; shared (org-wide) templates require admin.
  describe "template ownership enforcement" do
    let(:member_user) { create(:user, username: "tmplmember") }
    let!(:member_membership) { create(:membership, user: member_user, organization: org, role: "member", status: "active") }
    let(:member_headers) { auth_headers(member_user) }

    it "403s when a non-admin member creates a shared template" do
      post "/api/v1/orgs/#{org.key}/templates",
           params: { name: "Sneaky", body_html: "<p>x</p>", scope: "shared" }, headers: member_headers
      expect(response).to have_http_status(:forbidden)
    end

    it "allows a member to create a personal template" do
      post "/api/v1/orgs/#{org.key}/templates",
           params: { name: "Mine", body_html: "<p>x</p>", scope: "personal" }, headers: member_headers
      expect(response).to have_http_status(:created)
    end

    it "404s when a member updates a peer's personal template" do
      peer = Template.create!(organization: org, membership: membership, name: "Owner's", body_html: "<p>x</p>", scope: "personal")
      patch "/api/v1/orgs/#{org.key}/templates/#{peer.key}", params: { name: "Hijack" }, headers: member_headers
      expect(response).to have_http_status(:not_found)
      expect(peer.reload.name).to eq("Owner's")
    end

    it "403s when a non-admin member deletes a shared template" do
      shared = Template.create!(organization: org, membership: membership, name: "Team", body_html: "<p>x</p>", scope: "shared")
      delete "/api/v1/orgs/#{org.key}/templates/#{shared.key}", headers: member_headers
      expect(response).to have_http_status(:forbidden)
      expect(Template.exists?(shared.id)).to be(true)
    end

    it "403s when a member promotes a personal template to shared" do
      mine = Template.create!(organization: org, membership: member_membership, name: "Mine", body_html: "<p>x</p>", scope: "personal")
      patch "/api/v1/orgs/#{org.key}/templates/#{mine.key}", params: { scope: "shared" }, headers: member_headers
      expect(response).to have_http_status(:forbidden)
      expect(mine.reload.scope).to eq("personal")
    end
  end
end
