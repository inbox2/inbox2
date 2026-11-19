class PushDeviceSerializer < ::ApplicationSerializer
  # E4 minimal I/O — the raw push token is write-only; never expose it (or user_id).
  attributes :platform, :environment, :device_name, :last_registered_at,
    :created_at, :updated_at
end
