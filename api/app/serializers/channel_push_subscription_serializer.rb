class ChannelPushSubscriptionSerializer < ::ApplicationSerializer
  # E4 minimal I/O — never expose client_state or provider_subscription_id.
  attributes :provider, :external_email, :status, :expires_at, :lease_expires_at,
    :last_notification_at, :created_at, :updated_at
end
