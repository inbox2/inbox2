FactoryBot.define do
  factory :channel_push_subscription do
    user
    provider { ChannelPushSubscription::PROVIDER_GMAIL }
    sequence(:external_email) { |n| "mailbox#{n}@gmail.com" }
    provider_subscription_id { "sub-#{SecureRandom.hex(6)}" }
    client_state { SecureRandom.hex(8) }
    status { ChannelPushSubscription::STATUS_ACTIVE }
    expires_at { 7.days.from_now }
    last_seen_at { Time.current }
    lease_expires_at { ChannelPushSubscription::LEASE_DURATION.from_now }
  end
end
