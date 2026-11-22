module Disk
  # A Disk sync feed event (docs/Disk-Sync.md): a node gone from an org
  # ("deleted", node_key set) or an access change there ("acl"). Rows are written
  # by the Disk::SyncTriggers Postgres triggers, never by Rails.
  class SyncEvent < ApplicationRecord
    KIND_DELETED = "deleted".freeze
    KIND_ACL = "acl".freeze

    RETENTION = 30.days

    # Same watermark scheme as SyncTombstone.prune!: each org keeps its newest expired event.
    def self.prune!
      expired = where(created_at: ...RETENTION.ago)
      expired.where.not(id: expired.group(:organization_id).select("MAX(id)")).delete_all
    end

    def self.watermark_xid(organization_ids)
      where(organization_id: organization_ids, created_at: ...RETENTION.ago).maximum(:change_xid)
    end
  end
end
