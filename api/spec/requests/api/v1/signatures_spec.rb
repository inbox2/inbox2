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

  # Domain signatures and the applied map (spec 8.1.7: auto-applied per From address).
  describe "domain signatures" do
    let(:domain) { org.domains.find_by!(name: "sigs.com") }
    let(:other) { create(:user, username: "sigmember", display_name: "Sam Member") }
    let!(:other_membership) { create(:membership, user: other, organization: org, role: "member", status: "active") }

    it "lets an admin create one and applies it to a member's address with their name" do
      post "/api/v1/orgs/#{org.key}/signatures",
           params: { name: "Sigs", shared: true, domain_id: domain.key, body_html: "<p>{{name}} · {{email}}</p>" }, headers: headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["signature"]).to include("scope" => "domain", "domain_name" => "sigs.com", "editable" => true)

      get "/api/v1/orgs/#{org.key}/signatures", headers: auth_headers(other)
      applied = response.parsed_body["applied"]["sigmember@sigs.com"]
      expect(applied["html"]).to eq("<p>Sam Member · sigmember@sigs.com</p>")
      expect(applied["text"]).to eq("-- \nSam Member · sigmember@sigs.com")
      expect(response.parsed_body["signatures"].first["editable"]).to be(false)
    end

    it "hides another domain's and the org-wide signature from a mailbox-only member" do
      other_dom = create(:domain, organization: org, name: "other-sigs.com")
      Signature.create!(organization: org, domain: other_dom, name: "Other", body_html: "<p>o</p>")
      Signature.create!(organization: org, name: "Org", body_html: "<p>org</p>")
      mine = Signature.create!(organization: org, domain: domain, name: "Sigs", body_html: "<p>s</p>")
      allow_any_instance_of(Membership).to receive(:home_domain_ids).and_return([domain.id])
      allow_any_instance_of(Membership).to receive(:org_wide_access?).and_return(false)
      get "/api/v1/orgs/#{org.key}/signatures", headers: auth_headers(other)
      expect(response.parsed_body["signatures"].map { _1["id"] }).to eq([mine.key])
    end

    it "403s when a member creates a shared signature" do
      post "/api/v1/orgs/#{org.key}/signatures",
           params: { name: "Sigs", shared: true, domain_id: domain.key, body_html: "<p>x</p>" }, headers: auth_headers(other)
      expect(response).to have_http_status(:forbidden)
    end

    it "404s for a domain of another org" do
      foreign = create(:organization, owner: other, domain: "elsewhere.com").domains.first
      post "/api/v1/orgs/#{org.key}/signatures",
           params: { name: "Sigs", shared: true, domain_id: foreign.key, body_html: "<p>x</p>" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "prefers the person's own signature for the address, then the domain's, then their default" do
      dom = Signature.create!(organization: org, domain: domain, name: "Domain", body_html: "<p>domain</p>")
      default = Signature.create!(organization: org, membership: other_membership, name: "Mine", body_html: "<p>mine</p>", is_default: true)
      expect(Signature.for_address(other_membership, "sigmember@sigs.com")).to eq(dom)
      own = Signature.create!(organization: org, membership: other_membership, name: "Addr", body_html: "<p>a</p>", from_address: "sigmember@sigs.com")
      expect(Signature.for_address(other_membership, "SigMember@sigs.com")).to eq(own)
      expect(Signature.for_address(other_membership, "x@nodomain.com")).to eq(default)
      newer = Signature.create!(organization: org, domain: domain, name: "Domain 2", body_html: "<p>d2</p>", updated_at: 1.minute.from_now)
      own.destroy
      expect(Signature.for_address(other_membership, "sigmember@sigs.com")).to eq(newer)
    end
  end

  describe "body HTML" do
    it "drops scripts and handlers but keeps inline images" do
      img = "data:image/png;base64,iVBORw0KGgo="
      sig = Signature.create!(organization: org, membership: membership, name: "S",
                              body_html: %(<p onclick="x()">Hi<script>alert(1)</script><img src="#{img}" width="120"></p>))
      expect(sig.body_html).not_to include("script", "onclick")
      expect(sig.body_html).to include(%(src="#{img}"), %(width="120"))
    end

    it "refuses a body over the size limit" do
      sig = Signature.new(organization: org, membership: membership, name: "S",
                          body_html: %(<img src="data:image/png;base64,#{'A' * Signature::MAX_BODY_BYTES}">))
      expect(sig).not_to be_valid
    end
  end
end
