FactoryBot.define do
  factory :meta_channel_subscription do
    user
    channel { MetaChannelSubscription::CHANNEL_WHATSAPP }
    asset_type { MetaChannelSubscription::ASSET_PHONE }
    sequence(:asset_id) { |n| "asset-#{n}" }
    status { MetaChannelSubscription::STATUS_ACTIVE }
    last_seen_at { Time.current }
    lease_expires_at { MetaChannelSubscription::LEASE_DURATION.from_now }
  end
end
