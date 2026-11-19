# Meta channels (Instagram / Messenger / WhatsApp) webhook relay — see docs/Cloud-Push.md (Meta).
#
# Maps one Meta asset (Facebook Page, Instagram account, WhatsApp Business Account, or
# WhatsApp phone-number id) to the owning user, so the unauthenticated webhook receiver
# (MetaWebhooksController) can route an inbound event to the right device WITHOUT ever
# holding a Meta secret. The device (which holds the app_secret + System User token)
# subscribes its app's webhooks itself and registers only this routing row.
#
# One row per asset for O(1) routing. Lease model mirrors ChannelPushSubscription:
# every register/renew bumps lease_expires_at; a lapsed lease is reclaimed by the sweeper.
class MetaChannelSubscription < ApplicationRecord
  include HasPublicId
  key_prefix "mcs"

  # Account channel (which Meta surface the device account is).
  CHANNEL_INSTAGRAM = "instagram".freeze
  CHANNEL_MESSENGER = "messenger".freeze
  CHANNEL_WHATSAPP = "whatsapp".freeze
  CHANNELS = [CHANNEL_INSTAGRAM, CHANNEL_MESSENGER, CHANNEL_WHATSAPP].freeze

  # Asset kind, determines how the webhook payload is matched to this row.
  ASSET_PAGE = "page".freeze          # entry[].id on object=page
  ASSET_INSTAGRAM = "instagram".freeze # entry[].id on object=instagram
  ASSET_WABA = "waba".freeze          # entry[].id on object=whatsapp_business_account
  ASSET_PHONE = "phone".freeze        # value.metadata.phone_number_id (WhatsApp)
  ASSET_TYPES = [ASSET_PAGE, ASSET_INSTAGRAM, ASSET_WABA, ASSET_PHONE].freeze

  STATUS_ACTIVE = "active".freeze
  STATUS_EXPIRED = "expired".freeze
  STATUSES = [STATUS_ACTIVE, STATUS_EXPIRED].freeze

  LEASE_DURATION = 30.days

  belongs_to :user

  validates :channel, presence: true, inclusion: { in: CHANNELS }
  validates :asset_type, presence: true, inclusion: { in: ASSET_TYPES }
  validates :asset_id, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :asset_id, uniqueness: { scope: [:user_id, :asset_type] }

  scope :active, -> { where(status: STATUS_ACTIVE).where("lease_expires_at > ?", Time.current) }
  scope :lease_expired, -> { where(status: STATUS_ACTIVE).where("lease_expires_at <= ?", Time.current) }

  # Resolve the owning user for an inbound webhook asset. Used by the receiver.
  def self.owner_for(asset_type:, asset_id:)
    active.find_by(asset_type: asset_type, asset_id: asset_id)&.user
  end

  def live?
    status == STATUS_ACTIVE && lease_expires_at&.future?
  end
end
