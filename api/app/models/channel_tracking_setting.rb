# Cloud-synced open-tracking config for one local channel (Gmail/IMAP/Office365),
# keyed by the channel's email under the owning user so it follows them across
# devices. See docs/Open-Tracking.md.
class ChannelTrackingSetting < ApplicationRecord
  belongs_to :user

  validates :email_address, presence: true, uniqueness: { scope: :user_id, case_sensitive: false }

  before_validation { self.email_address = email_address.to_s.downcase.strip.presence }
  before_validation { self.track_domain = track_domain.to_s.downcase.strip.presence }
end
