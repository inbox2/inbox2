require "rails_helper"

RSpec.describe ChannelPushBroadcaster do
  let(:user) { create(:user, username: "broadcastuser") }

  it "broadcasts a content-free signal to the user's stream" do
    sub = create(:channel_push_subscription, user: user,
      provider: ChannelPushSubscription::PROVIDER_GMAIL, external_email: "me@gmail.com")

    payload = nil
    expect(ActionCable.server).to receive(:broadcast) do |stream, data|
      expect(stream).to eq("push_sync_#{user.key}")
      payload = data
    end

    described_class.call(sub, history_id: 999)

    expect(payload[:type]).to eq("channel_sync")
    expect(payload[:provider]).to eq("gmail")
    expect(payload[:email]).to eq("me@gmail.com")
    expect(payload[:history_id]).to eq(999)
    # Never leaks message content
    expect(payload.keys).to match_array(%i[type provider email history_id])
    expect(sub.reload.last_notification_at).to be_present
  end

  it "does not broadcast for an expired-lease subscription" do
    sub = create(:channel_push_subscription, user: user, lease_expires_at: 1.day.ago)
    expect(ActionCable.server).not_to receive(:broadcast)
    described_class.call(sub)
  end

  it "mirrors the signal as a silent mobile push" do
    sub = create(:channel_push_subscription, user: user,
      provider: ChannelPushSubscription::PROVIDER_GMAIL, external_email: "me@gmail.com")
    allow(ActionCable.server).to receive(:broadcast)

    expect(MobilePushSender).to receive(:channel_sync)
      .with(user, provider: "gmail", email: "me@gmail.com", history_id: 7)

    described_class.call(sub, history_id: 7)
  end

  it "does not let a mobile-push failure break webhook handling" do
    sub = create(:channel_push_subscription, user: user)
    allow(ActionCable.server).to receive(:broadcast)
    allow(MobilePushSender).to receive(:channel_sync).and_raise("apns down")

    expect { described_class.call(sub) }.not_to raise_error
  end
end
