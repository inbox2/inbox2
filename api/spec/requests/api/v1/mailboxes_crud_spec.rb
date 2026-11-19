require "rails_helper"

RSpec.describe "Api::V1::MailboxesCrud", type: :request do
  let(:owner) { create(:user) }
  let(:org) { create(:organization, owner: owner) }
  let!(:owner_m) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }
  let(:domain) { org.default_domain }
  let(:headers) { auth_headers(owner) }

  describe "POST /create" do
    it "creates a mailbox (address) for a member on a domain" do
      org.update!(mailbox_limit: 5)
      member = create(:user)
      m = create(:membership, user: member, organization: org, status: "active")
      expect {
        post "/api/v1/orgs/#{org.key}/mailboxes",
          params: { membership_id: m.key, domain_id: domain.key, local_part: "sales" }, headers: headers
      }.to change { org.mailboxes.count }.by(1)
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["mailbox"]["email_address"]).to eq("sales@#{domain.name}")
    end

    it "403s once the mailbox cap is reached" do
      org.update!(mailbox_limit: 1)
      create(:mailbox, membership: owner_m, domain: domain, local_part: "a")
      post "/api/v1/orgs/#{org.key}/mailboxes",
        params: { membership_id: owner_m.key, domain_id: domain.key, local_part: "b" }, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "422s a duplicate local_part on the same domain" do
      org.update!(mailbox_limit: 5)
      create(:mailbox, membership: owner_m, domain: domain, local_part: "dup")
      post "/api/v1/orgs/#{org.key}/mailboxes",
        params: { membership_id: owner_m.key, domain_id: domain.key, local_part: "dup" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "403s a non-admin member" do
      member = create(:user)
      m = create(:membership, user: member, organization: org, role: "member", status: "active")
      post "/api/v1/orgs/#{org.key}/mailboxes",
        params: { membership_id: m.key, domain_id: domain.key, local_part: "x" }, headers: auth_headers(member)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /index and DELETE /destroy" do
    it "lists and removes mailboxes" do
      org.update!(mailbox_limit: 5)
      mbx = create(:mailbox, membership: owner_m, domain: domain, local_part: "box")
      get "/api/v1/orgs/#{org.key}/mailboxes", headers: headers
      expect(response.parsed_body["mailboxes"].map { |m| m["local_part"] }).to include("box")

      expect {
        delete "/api/v1/orgs/#{org.key}/mailboxes/#{mbx.key}", headers: headers
      }.to change { org.mailboxes.count }.by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end
end
