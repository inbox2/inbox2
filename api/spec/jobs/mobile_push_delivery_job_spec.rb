require "rails_helper"

RSpec.describe MobilePushDeliveryJob do
  let(:user) { create(:user, username: "jobuser") }
  # Push is a paid feature (TODO 45.6) — give the user a paid org.
  let(:paid_org) { create(:organization, owner: user, domain: "jobteam.com") }
  let!(:paid_membership) { create(:membership, user: user, organization: paid_org, role: "owner", status: "active") }
  let!(:paid_subscription) { create(:subscription, organization: paid_org, plan: Plan.paid) }
  let(:spec) do
    { "kind" => "channel_sync", "data" => { "type" => "channel_sync" }, "alert" => nil, "collapse_id" => "c" }
  end

  before do
    allow(MobilePushConfig).to receive_messages(apns_configured?: true, fcm_configured?: true)
  end

  def result(ok:, status: nil, reason: nil)
    ApnsClient::Result.new(ok, status, reason)
  end

  it "delivers via APNs for an iOS device" do
    device = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS, environment: "sandbox")
    expect(ApnsClient).to receive(:deliver)
      .with(hash_including(token: device.token, environment: "sandbox"))
      .and_return(result(ok: true, status: 200))

    described_class.perform_now(device.id, spec)
  end

  describe "live_activity kind" do
    let(:live_spec) { { "kind" => "live_activity", "alert" => nil, "content_state" => { "conversationKey" => "conv_1", "sender" => "a", "subject" => "b" } } }

    it "push-to-starts via the start token when no activity is running" do
      device = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS, live_activity_start_token: "start-tok")
      expect(ApnsClient).to receive(:deliver) { |token:, headers:, body:, **|
        expect(token).to eq("start-tok")
        expect(headers["apns-push-type"]).to eq("liveactivity")
        expect(body["aps"]["event"]).to eq("start")
        expect(body["aps"]["content-state"]).to include("conversationKey" => "conv_1", "unread" => 0)
        result(ok: true, status: 200)
      }
      described_class.perform_now(device.id, live_spec)
    end

    it "updates the running activity's token instead of starting" do
      device = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS,
                      live_activity_start_token: "start-tok", live_activity_token: "act-tok")
      expect(ApnsClient).to receive(:deliver).once { |token:, body:, **|
        expect(token).to eq("act-tok")
        expect(body["aps"]["event"]).to eq("update")
        result(ok: true, status: 200)
      }
      described_class.perform_now(device.id, live_spec)
    end

    it "forgets a dead activity token without deleting the device" do
      device = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS, live_activity_token: "gone")
      allow(ApnsClient).to receive(:deliver).and_return(result(ok: false, status: 410, reason: "Unregistered"))
      described_class.perform_now(device.id, live_spec)
      expect(device.reload.live_activity_token).to be_nil
      expect(PushDevice.exists?(device.id)).to be(true)
    end

    it "falls back to a fresh start when the update token is dead" do
      device = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS,
                      live_activity_start_token: "start-tok", live_activity_token: "dead")
      events = []
      allow(ApnsClient).to receive(:deliver) { |token:, body:, **|
        events << [ token, body["aps"]["event"] ]
        token == "dead" ? result(ok: false, status: 410, reason: "Unregistered") : result(ok: true, status: 200)
      }
      described_class.perform_now(device.id, live_spec)
      expect(events).to eq([ [ "dead", "update" ], [ "start-tok", "start" ] ])
      expect(device.reload.live_activity_token).to be_nil
    end

    it "no-ops for a device with no ActivityKit token" do
      device = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS)
      expect(ApnsClient).not_to receive(:deliver)
      described_class.perform_now(device.id, live_spec)
    end
  end

  it "delivers via FCM for an Android device" do
    device = create(:push_device, user: user, platform: PushDevice::PLATFORM_ANDROID)
    expect(FcmClient).to receive(:deliver).and_return(FcmClient::Result.new(true, 200, nil))

    described_class.perform_now(device.id, spec)
  end

  it "deletes the device on an unregistered-token result and does not raise" do
    device = create(:push_device, user: user)
    allow(ApnsClient).to receive(:deliver).and_return(result(ok: false, status: 410, reason: "Unregistered"))

    expect { described_class.perform_now(device.id, spec) }.not_to raise_error
    expect(PushDevice.exists?(device.id)).to be(false)
  end

  it "re-enqueues itself (retry_on) on a transient failure and keeps the device" do
    device = create(:push_device, user: user)
    allow(ApnsClient).to receive(:deliver).and_return(result(ok: false, status: 503, reason: "ServiceUnavailable"))

    # retry_on intercepts TransientDeliveryError and schedules a retry.
    expect {
      described_class.perform_now(device.id, spec)
    }.to have_enqueued_job(described_class)
    expect(PushDevice.exists?(device.id)).to be(true)
  end

  it "logs and keeps the device on a permanent non-token failure" do
    device = create(:push_device, user: user)
    allow(ApnsClient).to receive(:deliver).and_return(result(ok: false, status: 400, reason: "BadMessageId"))

    expect { described_class.perform_now(device.id, spec) }.not_to raise_error
    expect(PushDevice.exists?(device.id)).to be(true)
  end

  it "no-ops when the device row is gone" do
    expect(ApnsClient).not_to receive(:deliver)
    described_class.perform_now(-1, spec)
  end

  it "no-ops when the platform is unconfigured" do
    allow(MobilePushConfig).to receive(:apns_configured?).and_return(false)
    device = create(:push_device, user: user, platform: PushDevice::PLATFORM_IOS)
    expect(ApnsClient).not_to receive(:deliver)

    expect { described_class.perform_now(device.id, spec) }.not_to raise_error
  end

  it "re-checks push_enabled? at delivery time" do
    allow_any_instance_of(User).to receive(:push_enabled?).and_return(false)
    device = create(:push_device, user: user)
    expect(ApnsClient).not_to receive(:deliver)

    described_class.perform_now(device.id, spec)
  end
end
