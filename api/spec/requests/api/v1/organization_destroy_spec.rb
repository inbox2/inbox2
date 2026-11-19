require "rails_helper"

RSpec.describe "Api::V1::Organizations destroy", type: :request do
  let(:owner) { create(:user, username: "destroyowner") }
  let(:org) { create(:organization, owner: owner, domain: "removeme.com") }
  let!(:owner_membership) { create(:membership, user: owner, organization: org, role: "owner", status: "active") }

  describe "DELETE /api/v1/orgs/:org_id" do
    context "positive" do
      it "removes the domain and cascades its data" do
        conv = create(:conversation, organization: org)
        delete "/api/v1/orgs/#{org.key}", headers: auth_headers(owner)
        expect(response).to have_http_status(:no_content)
        expect(Organization.exists?(org.id)).to be(false)
        expect(Conversation.exists?(conv.id)).to be(false)
      end
    end

    context "negative" do
      it "forbids a non-owner admin from deleting" do
        admin = create(:user, username: "destroyadmin")
        create(:membership, user: admin, organization: org, role: "admin", status: "active")
        delete "/api/v1/orgs/#{org.key}", headers: auth_headers(admin)
        expect(response).to have_http_status(:forbidden)
        expect(Organization.exists?(org.id)).to be(true)
      end

      it "404s for a non-member" do
        outsider = create(:user, username: "destroyoutsider")
        delete "/api/v1/orgs/#{org.key}", headers: auth_headers(outsider)
        expect(response).to have_http_status(:not_found)
        expect(Organization.exists?(org.id)).to be(true)
      end

      it "401s without auth" do
        delete "/api/v1/orgs/#{org.key}"
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
