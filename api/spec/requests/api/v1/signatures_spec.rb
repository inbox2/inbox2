require "rails_helper"

RSpec.describe "Api::V1::Signatures", type: :request do
  # E1 mapping: spec 8.1.7, A13.2 — Signatures
  let(:owner) { create(:user, username: "sigowner") }
  let(:org) { create(:organization, owner: owner, domain: "sigs.com") }
  let!(:membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(owner) }

  describe "POST /api/v1/orgs/:org_id/signatures" do
    it "creates a signature" do
      post "/api/v1/orgs/#{org.key}/signatures",
           params: { name: "Default", body_html: "<p>Best,<br>Me</p>", from_address: "me@sigs.com" },
           headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["signature"]["name"]).to eq("Default")
    end
  end

  describe "GET /api/v1/orgs/:org_id/signatures" do
    it "lists signatures" do
      Signature.create!(organization: org, membership: membership, name: "Mine", body_html: "<p>Sig</p>")
      get "/api/v1/orgs/#{org.key}/signatures", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["signatures"].length).to eq(1)
    end
  end

  describe "POST /api/v1/orgs/:org_id/signatures (negative)" do
    it "returns 422 when name is missing" do
      post "/api/v1/orgs/#{org.key}/signatures", params: { body_html: "<p>x</p>" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "requires authentication" do
      post "/api/v1/orgs/#{org.key}/signatures", params: { name: "X" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PATCH /api/v1/orgs/:org_id/signatures/:id" do
    let(:sig) { Signature.create!(organization: org, membership: membership, name: "Old", body_html: "<p>Sig</p>") }

    it "updates a signature" do
      patch "/api/v1/orgs/#{org.key}/signatures/#{sig.key}", params: { name: "New" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["signature"]["name"]).to eq("New")
    end

    it "returns 422 when name is blanked" do
      patch "/api/v1/orgs/#{org.key}/signatures/#{sig.key}", params: { name: "" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 404 for an unknown signature" do
      patch "/api/v1/orgs/#{org.key}/signatures/sig_missing", params: { name: "X" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/orgs/:org_id/signatures/:id" do
    it "deletes a signature" do
      sig = Signature.create!(organization: org, membership: membership, name: "Bye", body_html: "<p>Sig</p>")
      expect {
        delete "/api/v1/orgs/#{org.key}/signatures/#{sig.key}", headers: headers
      }.to change(Signature, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "returns 404 for an unknown signature" do
      delete "/api/v1/orgs/#{org.key}/signatures/sig_missing", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  # Horizontal authorization: a member may only mutate their own personal
  # signature; org-wide signatures require admin.
  describe "signature ownership enforcement" do
    let(:other) { create(:user, username: "sigother") }
    let!(:other_membership) { create(:membership, user: other, organization: org, role: "member", status: "active") }
    let(:other_headers) { auth_headers(other) }
    let(:peer_sig) { Signature.create!(organization: org, membership: membership, name: "Owner's", body_html: "<p>x</p>") }
    let(:org_sig) { Signature.create!(organization: org, membership: nil, name: "Org-wide", body_html: "<p>x</p>") }

    it "404s when a member updates a peer's personal signature" do
      patch "/api/v1/orgs/#{org.key}/signatures/#{peer_sig.key}", params: { name: "Hijack" }, headers: other_headers
      expect(response).to have_http_status(:not_found)
      expect(peer_sig.reload.name).to eq("Owner's")
    end

    it "404s when a member deletes a peer's personal signature" do
      peer_sig
      expect {
        delete "/api/v1/orgs/#{org.key}/signatures/#{peer_sig.key}", headers: other_headers
      }.not_to change(Signature, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "403s when a non-admin member updates an org-wide signature" do
      patch "/api/v1/orgs/#{org.key}/signatures/#{org_sig.key}", params: { name: "Hijack" }, headers: other_headers
      expect(response).to have_http_status(:forbidden)
      expect(org_sig.reload.name).to eq("Org-wide")
    end

    it "allows an admin to update an org-wide signature" do
      patch "/api/v1/orgs/#{org.key}/signatures/#{org_sig.key}", params: { name: "Updated" }, headers: headers
      expect(response).to have_http_status(:ok)
    end
  end
end
