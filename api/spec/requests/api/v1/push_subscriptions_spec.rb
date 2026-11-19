require "rails_helper"

RSpec.describe "Api::V1::PushSubscriptions", type: :request do
  let(:user) { create(:user, username: "pushuser") }
  let(:headers) { auth_headers(user) }

  describe "POST /api/v1/push-subscriptions (spec 10.4, A14.4)" do
    it "creates a push subscription" do
      expect {
        post "/api/v1/push-subscriptions",
             params: {
               endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
               p256dh_key: "BNcRdre9AIdQ1_abc",
               auth_key: "auth_key_abc"
             },
             headers: headers
      }.to change(PushSubscription, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["subscribed"]).to be true
    end

    it "updates existing subscription by endpoint" do
      PushSubscription.create!(
        user: user,
        endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
        p256dh_key: "old_key",
        auth_key: "old_auth"
      )

      expect {
        post "/api/v1/push-subscriptions",
             params: {
               endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
               p256dh_key: "new_key",
               auth_key: "new_auth"
             },
             headers: headers
      }.not_to change(PushSubscription, :count)

      expect(response).to have_http_status(:created)
      expect(PushSubscription.last.p256dh_key).to eq("new_key")
    end

    it "rejects without required fields" do
      post "/api/v1/push-subscriptions",
           params: { endpoint: "https://example.com" },
           headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /api/v1/push-subscriptions" do
    it "removes a push subscription" do
      PushSubscription.create!(
        user: user,
        endpoint: "https://fcm.googleapis.com/fcm/send/to-remove",
        p256dh_key: "key",
        auth_key: "auth"
      )

      expect {
        delete "/api/v1/push-subscriptions",
               params: { endpoint: "https://fcm.googleapis.com/fcm/send/to-remove" },
               headers: headers
      }.to change(PushSubscription, :count).by(-1)

      expect(response).to have_http_status(:no_content)
    end
  end

  describe "GET /api/v1/push-subscriptions/vapid" do
    it "returns the VAPID public key" do
      get "/api/v1/push-subscriptions/vapid", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to have_key("vapid_public_key")
    end
  end
end
