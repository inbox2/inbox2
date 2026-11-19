require "rails_helper"

RSpec.describe "Api::V1::Notifications", type: :request do
  let(:user) { create(:user, username: "notifuser") }
  let(:org) { create(:organization, owner: user, domain: "notif.com") }
  let!(:membership) { create(:membership, user: user, organization: org, role: "owner", status: "active") }
  let(:headers) { auth_headers(user) }

  # --- Spec 10.1, A14.1 — List notifications ---
  describe "GET /api/v1/notifications" do
    it "lists notifications for the current user" do
      create(:notification, user: user, organization: org, title: "Note 1")
      create(:notification, user: user, organization: org, title: "Note 2")

      get "/api/v1/notifications", headers: headers
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["notifications"].length).to eq(2)
      body["notifications"].each do |n|
        expect(n["id"]).to start_with("ntf_")
        expect(n).not_to have_key("user_id")
      end
    end

    it "does not show other users' notifications" do
      other = create(:user, username: "othernotif")
      create(:notification, user: other, organization: org, title: "Private")

      get "/api/v1/notifications", headers: headers
      expect(response.parsed_body["notifications"].length).to eq(0)
    end
  end

  # --- Spec A14.2 — Mark read ---
  describe "POST /api/v1/notifications/read" do
    it "marks specific notifications as read" do
      n1 = create(:notification, user: user, organization: org, read: false)
      n2 = create(:notification, user: user, organization: org, read: false)

      post "/api/v1/notifications/read",
           params: { notification_ids: [n1.key] },
           headers: headers
      expect(response).to have_http_status(:no_content)
      expect(n1.reload.read).to eq(true)
      expect(n2.reload.read).to eq(false)
    end

    it "marks all as read when no IDs given" do
      create(:notification, user: user, organization: org, read: false)
      create(:notification, user: user, organization: org, read: false)

      post "/api/v1/notifications/read", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(user.notifications.unread.count).to eq(0)
    end
  end

  describe "notifications — auth required" do
    it "rejects unauthenticated index" do
      get "/api/v1/notifications"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects unauthenticated mark-read" do
      post "/api/v1/notifications/read"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
