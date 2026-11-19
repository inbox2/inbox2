require "rails_helper"

RSpec.describe "Api::V1::Saas::Users", :saas, type: :request do
  let(:credential) { create(:admin_credential) }
  let(:headers) { saas_headers(credential) }

  def json = JSON.parse(response.body)

  describe "GET /index" do
    it "lists and searches users across all tenants" do
      create(:user, username: "alice_op", billing_email: "alice@x.test")
      create(:user, username: "bob_op", billing_email: "bob@x.test")

      get "/api/v1/saas/users", params: { q: "alice" }, headers: headers
      expect(response).to have_http_status(:ok)
      usernames = json["users"].map { |u| u["username"] }
      expect(usernames).to include("alice_op")
      expect(usernames).not_to include("bob_op")
    end
  end

  describe "GET /show" do
    it "returns the user with memberships and effective plan" do
      user = create(:user)
      create(:membership, user: user)
      get "/api/v1/saas/users/#{user.key}", headers: headers
      expect(response).to have_http_status(:ok)
      expect(json["user"]["id"]).to eq(user.key)
      expect(json["user"]["memberships"].size).to eq(1)
    end
  end

  describe "POST /reset_password" do
    it "enqueues the reset email and issues a token" do
      user = create(:user, billing_email: "reset@me.test")
      expect {
        post "/api/v1/saas/users/#{user.key}/reset_password", headers: headers
      }.to have_enqueued_job(MessyTriggerJob)
      expect(response).to have_http_status(:accepted)
      expect(user.reload.reset_token).to be_present
    end

    it "422s when the user has no billing email" do
      user = create(:user, billing_email: nil)
      post "/api/v1/saas/users/#{user.key}/reset_password", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "disable / enable" do
    it "disables every membership and re-enables them" do
      user = create(:user)
      create(:membership, user: user, status: Membership::STATUS_ACTIVE)

      post "/api/v1/saas/users/#{user.key}/disable", headers: headers
      expect(response).to have_http_status(:ok)
      expect(user.memberships.pluck(:status).uniq).to eq([Membership::STATUS_DISABLED])

      post "/api/v1/saas/users/#{user.key}/enable", headers: headers
      expect(user.memberships.pluck(:status).uniq).to eq([Membership::STATUS_ACTIVE])
    end
  end

  describe "DELETE /offboard" do
    it "removes the user from every domain" do
      user = create(:user)
      create(:membership, user: user, status: Membership::STATUS_ACTIVE)

      expect {
        delete "/api/v1/saas/users/#{user.key}/offboard", headers: headers
      }.to change { Membership.where(user: user).count }.to(0)
      expect(response).to have_http_status(:no_content)
    end
  end
end
