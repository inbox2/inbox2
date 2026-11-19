class MetaChannelSubscriptionSerializer < ::ApplicationSerializer
  # E4 minimal I/O — only the routing mapping + lease state. No Meta secrets exist
  # on this record to leak.
  attributes :channel, :asset_type, :asset_id, :status, :lease_expires_at,
    :last_seen_at, :created_at, :updated_at
end
