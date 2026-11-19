require "rails_helper"

RSpec.describe ChannelPushSubscriptionSweeperJob do
  describe "#perform" do
    it "expires active subscriptions whose lease has lapsed" do
      stale = create(:channel_push_subscription, lease_expires_at: 1.day.ago)
      fresh = create(:channel_push_subscription, lease_expires_at: 10.days.from_now)

      count = described_class.new.perform

      expect(count).to eq(1)
      expect(stale.reload.status).to eq(ChannelPushSubscription::STATUS_EXPIRED)
      expect(fresh.reload.status).to eq(ChannelPushSubscription::STATUS_ACTIVE)
    end

    it "leaves a within-lease subscription untouched (monthly boundary)" do
      sub = create(:channel_push_subscription,
        lease_expires_at: (ChannelPushSubscription::LEASE_DURATION - 1.hour).from_now)

      described_class.new.perform

      expect(sub.reload.status).to eq(ChannelPushSubscription::STATUS_ACTIVE)
    end

    it "drops an expired subscription out of the active scope so it stops broadcasting" do
      sub = create(:channel_push_subscription, lease_expires_at: 1.day.ago)
      described_class.new.perform
      expect(ChannelPushSubscription.active).not_to include(sub.reload)
    end
  end
end
