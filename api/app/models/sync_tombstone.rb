# A deleted synced record (docs/MX-Sync.md). Rows are written by the
# `sync_tombstone` Postgres trigger, never by Rails.
class SyncTombstone < ApplicationRecord
  TYPE_CONVERSATION = "conversation".freeze
  TYPE_MESSAGE = "message".freeze
  TYPE_NOTE = "note".freeze

  RETENTION = 90.days

  # ponytail: each org's newest expired tombstone is kept as its watermark — a
  # cursor older than it may have missed pruned deletes (SyncController#cursor_expired?).
  # A dedicated watermark table if tombstones ever need pruning by anything but age.
  def self.prune!
    expired = where(created_at: ...RETENTION.ago)
    expired.where.not(id: expired.group(:organization_id).select("MAX(id)")).delete_all
  end

  def self.watermark_xid(organization_id)
    where(organization_id: organization_id, created_at: ...RETENTION.ago).maximum(:change_xid)
  end
end
