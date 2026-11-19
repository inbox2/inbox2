class ApiKeySerializer < ::ApplicationSerializer
  # `device_platform` is set only for keys minted by the device-link flow
  # (desktop/ios/android); nil for keys created manually in account settings. The
  # account "Linked devices" UI keys off it.
  attributes :name, :prefix, :scopes, :device_platform, :last_used_at, :expires_at, :created_at
end
