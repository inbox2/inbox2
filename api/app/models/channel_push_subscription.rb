# Cloud push for local channels (Gmail / Office365) — see docs/Cloud-Push.md
#
# Maps a provider-side push subscription (Gmail Pub/Sub watch, Microsoft Graph
# subscription) to a user, WITHOUT ever storing the OAuth token. The desktop client
# (which holds the token) creates the provider subscription pointing its webhook/topic
# at our Rails backend, then registers the mapping here. Provider webhooks are matched
# back to a user via this row, and a content-free "go sync" signal is fanned out over
# ActionCable (PushSyncChannel).
#
# Lease model: every connect/renew bumps lease_expires_at. ChannelPushSubscriptionSweeperJob
# expires rows whose lease has lapsed so abandoned subscriptions are reclaimed.
class ChannelPushSubscription < ApplicationRecord
  include HasPublicId
  key_prefix "cpsub"

  PROVIDER_GMAIL = "gmail".freeze
  PROVIDER_MICROSOFT = "microsoft".freeze
  PROVIDERS = [PROVIDER_GMAIL, PROVIDER_MICROSOFT].freeze

  STATUS_ACTIVE = "active".freeze
  STATUS_EXPIRED = "expired".freeze
  STATUS_REVOKED = "revoked".freeze
  STATUSES = [STATUS_ACTIVE, STATUS_EXPIRED, STATUS_REVOKED].freeze

  # How long a client may stay away before the subscription is reclaimed (§1a).
  LEASE_DURATION = 30.days

  belongs_to :user

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :external_email, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :external_email, uniqueness: { scope: [:user_id, :provider] }

  scope :active, -> { where(status: STATUS_ACTIVE).where("lease_expires_at > ?", Time.current) }
  scope :lease_expired, -> { where(status: STATUS_ACTIVE).where("lease_expires_at <= ?", Time.current) }
  # Provider-side subscription (Gmail watch / Graph sub) hasn't passed its expiry.
  # The Rails lease (30d) outlives the much shorter provider expiry (~7d Gmail,
  # ~3d Microsoft), so a row can be lease-`active` yet dead on the provider — it no
  # longer receives webhooks. The client's "do I need to register?" check (index)
  # must treat those as absent so it re-registers, instead of trusting the stale
  # lease and leaving push silently dead until the lease lapses. NULL = never
  # recorded an expiry → treat as live (don't churn). See docs/Cloud-Push.md.
  scope :provider_live, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  # Live = the lease is still valid and the provider sub hasn't been revoked/expired.
  # Mirrors the `active` scope for in-memory guards (e.g. the broadcaster).
  def live?
    status == STATUS_ACTIVE && lease_expires_at&.future?
  end
end
