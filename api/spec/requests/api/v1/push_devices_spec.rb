require "rails_helper"

# Mobile push device tokens (APNs/FCM) — see docs/Cloud-Push.md "Mobile push"
RSpec.describe "Api::V1::PushDevices", type: :request do
  let(:user) { create(:user, username: "deviceuser") }
  let(:headers) { auth_headers(user) }
  # Push is a paid feature (TODO 45.6) — give the user a paid org.
  let(:org) { create(:organization, owner: user, domain: "deviceteam.com") }
  let!(:membership) { create(:membership, user: user, organization: org, role: "owner", status: "active") }
  let!(:subscription) { create(:subscription, organization: org, plan: Plan.paid) }

  describe "POST /api/v1/push-devices/live-activity" do
    let!(:device) { create(:push_device, user: user, token: "apns-la", platform: "ios") }

    it "stores the tokens independently and clears one with null" do
      post "/api/v1/push-devices/live-activity", params: { token: "apns-la", start_token: "st1" }, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(device.reload.live_activity_start_token).to eq("st1")
      expect(device.live_activity_token).to be_nil

      post "/api/v1/push-devices/live-activity", params: { token: "apns-la", activity_token: "act1" }, headers: headers
      expect(device.reload.live_activity_start_token).to eq("st1")
      expect(device.live_activity_token).to eq("act1")

      post "/api/v1/push-devices/live-activity", params: { token: "apns-la", activity_token: nil }.to_json,
        headers: headers.merge("CONTENT_TYPE" => "application/json")
      expect(device.reload.live_activity_token).to be_nil
    end

    it "start: fans a live_activity push with the allow-listed content to this device only" do
      allow(MobilePushConfig).to receive_messages(configured?: true, apns_configured?: true)
      device.update!(live_activity_start_token: "st")
      create(:push_device, user: user, token: "apns-other", platform: "ios", live_activity_start_token: "st2")
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear

      post "/api/v1/push-devices/live-activity/start",
        params: { token: "apns-la", content_state: { conversationKey: "c1", accountKey: "acct", orgId: "",
                                                      sender: "boss", subject: "hi", snippet: "yo", evil: "x" } },
        headers: headers

      expect(response).to have_http_status(:accepted)
      jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j["job_class"] == "MobilePushDeliveryJob" }
      expect(jobs.size).to eq(1)
      args = ActiveJob::Arguments.deserialize(jobs.first["arguments"])
      expect(args.first).to eq(device.id)
      expect(args.last["kind"]).to eq("live_activity")
      expect(args.last["content_state"]).to eq("conversationKey" => "c1", "accountKey" => "acct", "orgId" => "",
                                                "sender" => "boss", "subject" => "hi", "snippet" => "yo")
    end

    it "404s for another user's device" do
      other = create(:user, username: "otherla")
      create(:push_device, user: other, token: "theirs", platform: "ios")
      post "/api/v1/push-devices/live-activity", params: { token: "theirs", start_token: "x" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/v1/push-devices" do
    it "registers a device and never exposes the token" do
      post "/api/v1/push-devices",
        params: { token: "apns-abc123", platform: "ios", environment: "sandbox", device_name: "Waseem's iPhone" },
        headers: headers

      expect(response).to have_http_status(:created)
      device = response.parsed_body["device"]
      expect(device["id"]).to start_with("pdev_")
      expect(device["platform"]).to eq("ios")
      expect(device["environment"]).to eq("sandbox")
      expect(device["device_name"]).to eq("Waseem's iPhone")
      # E4: the raw push token is write-only
      expect(device).not_to have_key("token")
      expect(device).not_to have_key("user_id")
      expect(PushDevice.count).to eq(1)
    end

    it "defaults environment to production" do
      post "/api/v1/push-devices", params: { token: "fcm-xyz", platform: "android" }, headers: headers

      expect(response).to have_http_status(:created)
      expect(PushDevice.last.environment).to eq(PushDevice::ENV_PRODUCTION)
    end

    it "is idempotent on token — re-registering updates the existing row" do
      post "/api/v1/push-devices", params: { token: "apns-abc", platform: "ios" }, headers: headers
      post "/api/v1/push-devices", params: { token: "apns-abc", platform: "ios", device_name: "Renamed" }, headers: headers

      expect(response).to have_http_status(:created)
      expect(PushDevice.count).to eq(1)
      expect(PushDevice.last.device_name).to eq("Renamed")
    end

    it "moves a token to the new account when a different user registers it" do
      other = create(:user, username: "otheruser")
      create(:push_device, user: other, token: "shared-device")

      post "/api/v1/push-devices", params: { token: "shared-device", platform: "ios" }, headers: headers

      expect(response).to have_http_status(:created)
      expect(PushDevice.count).to eq(1)
      expect(PushDevice.last.user).to eq(user)
    end

    it "rejects an unknown platform" do
      post "/api/v1/push-devices", params: { token: "t", platform: "blackberry" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["errors"]).to be_present
    end

    it "rejects a blank token" do
      post "/api/v1/push-devices", params: { platform: "ios" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 403 when push is not enabled for the account" do
      allow_any_instance_of(User).to receive(:push_enabled?).and_return(false)

      post "/api/v1/push-devices", params: { token: "t", platform: "ios" }, headers: headers

      expect(response).to have_http_status(:forbidden)
      expect(PushDevice.count).to eq(0)
    end

    it "requires authentication" do
      post "/api/v1/push-devices", params: { token: "t", platform: "ios" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/push-devices/unread" do
    it "updates the device's reported channel-unread count" do
      create(:push_device, user: user, token: "mine", channel_unread: 0)

      post "/api/v1/push-devices/unread", params: { token: "mine", channel_unread: 7 }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(PushDevice.find_by(token: "mine").channel_unread).to eq(7)
    end

    it "accepts channel_unread at registration time" do
      post "/api/v1/push-devices",
        params: { token: "apns-c", platform: "ios", channel_unread: 3 }, headers: headers

      expect(response).to have_http_status(:created)
      expect(PushDevice.last.channel_unread).to eq(3)
    end

    it "404s for a token the caller doesn't own (E3)" do
      other = create(:user, username: "otheruser")
      create(:push_device, user: other, token: "theirs", channel_unread: 1)

      post "/api/v1/push-devices/unread", params: { token: "theirs", channel_unread: 9 }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(PushDevice.find_by(token: "theirs").channel_unread).to eq(1)
    end

    it "requires authentication" do
      post "/api/v1/push-devices/unread", params: { token: "mine", channel_unread: 1 }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "DELETE /api/v1/push-devices" do
    it "removes the caller's device by token" do
      create(:push_device, user: user, token: "mine")

      delete "/api/v1/push-devices", params: { token: "mine" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(PushDevice.count).to eq(0)
    end

    it "is idempotent for an unknown token" do
      delete "/api/v1/push-devices", params: { token: "never-registered" }, headers: headers

      expect(response).to have_http_status(:no_content)
    end

    it "never removes another user's device (E3)" do
      other = create(:user, username: "otheruser")
      create(:push_device, user: other, token: "theirs")

      delete "/api/v1/push-devices", params: { token: "theirs" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(PushDevice.count).to eq(1)
    end

    it "requires authentication" do
      delete "/api/v1/push-devices", params: { token: "t" }

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
