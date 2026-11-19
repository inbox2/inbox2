# No public id — channels are addressed by their email, not a prefixed key, so
# this includes Alba::Resource directly instead of ApplicationSerializer.
class ChannelTrackingSettingSerializer
  include Alba::Resource

  attributes :email_address, :open_tracking_enabled, :track_domain
end
