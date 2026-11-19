require "rails_helper"

RSpec.describe MobilePushPayloadBuilder do
  let(:silent_spec) do
    {
      "kind" => "channel_sync",
      "data" => { "type" => "channel_sync", "provider" => "gmail", "email" => "me@gmail.com" },
      "alert" => nil,
      "collapse_id" => "csync-abc"
    }
  end

  let(:visible_spec) do
    {
      "kind" => "new_message",
      "data" => { "type" => "new_message", "conversation_id" => "conv_1", "message_id" => "msg_1" },
      "alert" => { "title" => "boss@corp.com", "body" => "Numbers — see attached" },
      "collapse_id" => "msg_1",
      "thread_id" => "conv_1"
    }
  end

  let(:badge_spec) do
    { "kind" => MobilePushSender::KIND_BADGE, "alert" => nil, "collapse_id" => "badge", "badge" => 3 }
  end

  describe ".apns_body category" do
    it "uses the OTP categories for sign-in mail, MAIL otherwise" do
      expect(described_class.apns_body(visible_spec)["aps"]["category"]).to eq("MAIL")
      code = visible_spec.merge("data" => visible_spec["data"].merge("otp_code" => "482910"))
      expect(described_class.apns_body(code)["aps"]["category"]).to eq("OTP_CODE")
      link = visible_spec.merge("data" => visible_spec["data"].merge("otp_link" => "https://x.test/l", "otp_host" => "x.test"))
      expect(described_class.apns_body(link)["aps"]["category"]).to eq("OTP_LINK")
    end
  end

  describe ".apns_headers" do
    it "marks silent pushes as background priority 5" do
      headers = described_class.apns_headers(silent_spec)
      expect(headers["apns-push-type"]).to eq("background")
      expect(headers["apns-priority"]).to eq("5")
      expect(headers["apns-topic"]).to eq(MobilePushConfig.apns_topic)
      expect(headers["apns-collapse-id"]).to eq("csync-abc")
    end

    it "marks visible pushes as alert priority 10" do
      headers = described_class.apns_headers(visible_spec)
      expect(headers["apns-push-type"]).to eq("alert")
      expect(headers["apns-priority"]).to eq("10")
    end

    # The bug this guards: on the background lane APNs throttles the push, so a
    # badge change made on another device never reaches the phone.
    it "sends a badge-only refresh on the alert lane, not the background lane" do
      headers = described_class.apns_headers(badge_spec)
      expect(headers["apns-push-type"]).to eq("alert")
      expect(headers["apns-priority"]).to eq("10")
    end
  end

  describe ".apns_body" do
    it "builds a content-available body with no alert for silent pushes" do
      body = described_class.apns_body(silent_spec)
      expect(body["aps"]).to eq("content-available" => 1)
      expect(body["provider"]).to eq("gmail")
      expect(body["aps"]).not_to have_key("alert")
      expect(body["aps"]).not_to have_key("sound")
    end

    it "builds an alert body with sound and thread id for visible pushes" do
      body = described_class.apns_body(visible_spec)
      expect(body["aps"]["alert"]).to eq("title" => "boss@corp.com", "body" => "Numbers — see attached")
      expect(body["aps"]["sound"]).to eq("default")
      expect(body["aps"]["thread-id"]).to eq("conv_1")
      expect(body["conversation_id"]).to eq("conv_1")
    end

    it "builds a push-to-start Live Activity body with attributes + alert, and a bare update" do
      spec = { "kind" => "live_activity", "content_state" => { "conversationKey" => "conv_1", "sender" => "boss@corp.com", "subject" => "Numbers" } }
      start = described_class.apns_live_activity_body(spec, event: "start", unread: 4)["aps"]
      expect(start["event"]).to eq("start")
      expect(start["attributes-type"]).to eq("MailActivityAttributes")
      expect(start["attributes"]).to eq({})
      expect(start["alert"]).to eq("title" => "boss@corp.com", "body" => "Numbers")
      expect(start["content-state"]).to include("conversationKey" => "conv_1", "unread" => 4)
      expect(start["content-state"]["receivedAt"]).to be_a(Float)

      update = described_class.apns_live_activity_body(spec, event: "update", unread: 3)["aps"]
      expect(update["event"]).to eq("update")
      expect(update).not_to have_key("attributes-type")
      expect(update).not_to have_key("alert")

      headers = described_class.apns_live_activity_headers
      expect(headers["apns-push-type"]).to eq("liveactivity")
      expect(headers["apns-topic"]).to end_with(".push-type.liveactivity")
    end

    it "stamps the MAIL action category on new-message alerts only" do
      expect(described_class.apns_body(visible_spec)["aps"]["category"]).to eq("MAIL")
      expect(described_class.apns_body(badge_spec)["aps"]).not_to have_key("category")
    end

    it "includes the app-icon badge when the spec carries one (even at 0)" do
      expect(described_class.apns_body(visible_spec.merge("badge" => 4))["aps"]["badge"]).to eq(4)
      expect(described_class.apns_body(silent_spec.merge("badge" => 0))["aps"]["badge"]).to eq(0)
    end

    it "builds a badge-only body — no alert, no content-available" do
      aps = described_class.apns_body(badge_spec)["aps"]
      expect(aps).to eq("badge" => 3)
    end

    it "omits the badge when the spec has none" do
      expect(described_class.apns_body(silent_spec)["aps"]).not_to have_key("badge")
    end
  end

  describe ".fcm_message" do
    it "builds a data-only high-priority message for silent pushes" do
      message = described_class.fcm_message(silent_spec, token: "tok")["message"]
      expect(message["token"]).to eq("tok")
      expect(message).not_to have_key("notification")
      expect(message["android"]["priority"]).to eq("HIGH")
      expect(message["android"]["collapse_key"]).to eq("csync-abc")
      expect(message["data"].values).to all(be_a(String))
    end

    it "keeps visible pushes data-only, with the alert riding the data map (the app posts the banner itself)" do
      message = described_class.fcm_message(visible_spec, token: "tok")["message"]
      expect(message).not_to have_key("notification")
      expect(message["data"]["title"]).to eq("boss@corp.com")
      expect(message["data"]["body"]).to eq("Numbers — see attached")
      expect(message["data"]["conversation_id"]).to eq("conv_1")
      expect(message["android"]["priority"]).to eq("HIGH")
    end
  end
end
