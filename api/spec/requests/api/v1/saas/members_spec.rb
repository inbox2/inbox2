require "rails_helper"

RSpec.describe "Api::V1::Saas::Members", :saas, type: :request do
  let(:credential) { create(:admin_credential) }
  let(:headers) { saas_headers(credential) }
  let(:org) { create(:organization) }

  def json = JSON.parse(response.body)

  describe "GET /index" do
    it "lists the org's members" do
      create(:membership, organization: org)
      get "/api/v1/saas/organizations/#{org.key}/members", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json["members"].size).to eq(1)
    end
  end

  describe "POST /create" do
    it "adds an invited member" do
      expect {
        post "/api/v1/saas/organizations/#{org.key}/members",
          params: { email: "new@person.test", role: "member" }, headers: headers
      }.to change { org.memberships.count }.by(1)
      expect(response).to have_http_status(:created)
      expect(json["member"]["status"]).to eq(Membership::STATUS_INVITED)
    end

    it "adds a member regardless of the mailbox cap (members are not addresses)" do
      org.update!(mailbox_limit: 1)
      create(:membership, organization: org, status: Membership::STATUS_ACTIVE)

      expect {
        post "/api/v1/saas/organizations/#{org.key}/members",
          params: { email: "another@person.test" }, headers: headers
      }.to change { org.memberships.count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "422s without an email" do
      post "/api/v1/saas/organizations/#{org.key}/members", params: {}, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /destroy" do
    it "offboards the member from the domain" do
      membership = create(:membership, organization: org, status: Membership::STATUS_ACTIVE)
      expect {
        delete "/api/v1/saas/organizations/#{org.key}/members/#{membership.key}", headers: headers
      }.to change { org.memberships.count }.by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end
end
