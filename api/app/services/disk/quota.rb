module Disk
  # The org's pooled quota and its meter (docs/plans/disk-build.md sections 1
  # and 8). Used and reserved live on the organization row. Every version
  # counts, current or old, live or in the trash; thumbnails and renditions do not.
  class Quota
    FULL = "disk_quota_exceeded".freeze

    attr_reader :organization

    def initialize(organization)
      @organization = organization
    end

    def pool_bytes = organization.disk_quota_bytes
    def used_bytes = organization.disk_bytes_used
    def reserved_bytes = organization.disk_bytes_reserved
    def available_bytes = [pool_bytes - used_bytes - reserved_bytes, 0].max

    def percent_used
      return 0 if pool_bytes.zero?

      ((used_bytes + reserved_bytes) * 100.0 / pool_bytes).round(1)
    end

    def fits?(bytes) = used_bytes + reserved_bytes + bytes <= pool_bytes

    # Used bytes split by kind: current files, older versions, and the trash
    # (deleted items and everything in a deleted share).
    def files_bytes = breakdown[0]
    def versions_bytes = breakdown[1]
    def trash_bytes = breakdown[2]

    # Current files split by type, for the sidebar meter's tooltip: { "images" => bytes, ... }.
    # Sealed files are one group; their types are encrypted.
    def types_bytes
      @types_bytes ||= Disk::Version.connection.select_rows(Disk::Version.sanitize_sql([<<~SQL.squish, organization.id])).to_h { |k, v| [k, v.to_i] }
        SELECT CASE
                 WHEN n.sealed THEN 'sealed'
                 WHEN n.mime LIKE 'image/%' THEN 'images'
                 WHEN n.mime LIKE 'video/%' THEN 'video'
                 WHEN n.mime LIKE 'audio/%' THEN 'audio'
                 WHEN n.mime LIKE 'text/%' OR n.mime = 'application/pdf' OR n.mime LIKE 'application/vnd.%' OR n.mime = 'application/msword' THEN 'documents'
                 ELSE 'other'
               END AS type, SUM(v.size_bytes)
        FROM disk_versions v
        JOIN disk_nodes n ON n.id = v.node_id AND n.current_version_id = v.id AND n.trashed_at IS NULL
        LEFT JOIN disk_shares s ON s.id = n.share_id
        WHERE v.organization_id = ? AND s.trashed_at IS NULL
        GROUP BY 1
      SQL
    end

    # Inside a transaction: locks the org row and refuses unless `bytes` more
    # fit. The caller then moves the figures with move! before committing, so
    # two uploads racing for the last space cannot both get it.
    def self.check!(organization_id, bytes)
      org = Organization.lock.find(organization_id)
      quota = new(org)
      return org if quota.fits?(bytes)

      raise Disk::Refused.new("Not enough Disk space: this needs #{fmt(bytes)} and #{fmt(quota.available_bytes)} is free",
                              code: FULL)
    end

    # Atomic adjustments of the org's reserved and used figures.
    # A change in used bytes re-checks the 80 and 100 percent warnings once committed.
    def self.move!(organization_id, reserved: 0, used: 0)
      Organization.where(id: organization_id).update_all(
        ["disk_bytes_reserved = disk_bytes_reserved + ?, disk_bytes_used = disk_bytes_used + ?", reserved, used]
      )
      ActiveRecord.after_all_transactions_commit { Disk::Lifecycle.check_quota!(organization_id) } unless used.zero?
    end

    def self.fmt(bytes) = ActiveSupport::NumberHelper.number_to_human_size(bytes)

    private

    def breakdown
      @breakdown ||= Disk::Version.connection.select_rows(Disk::Version.sanitize_sql([<<~SQL.squish, organization.id])).first.map(&:to_i)
        SELECT COALESCE(SUM(v.size_bytes) FILTER (WHERE NOT trashed AND n.current_version_id = v.id), 0),
               COALESCE(SUM(v.size_bytes) FILTER (WHERE NOT trashed AND n.current_version_id IS DISTINCT FROM v.id), 0),
               COALESCE(SUM(v.size_bytes) FILTER (WHERE trashed), 0)
        FROM disk_versions v
        JOIN disk_nodes n ON n.id = v.node_id
        LEFT JOIN disk_shares s ON s.id = n.share_id,
        LATERAL (SELECT n.trashed_at IS NOT NULL OR s.trashed_at IS NOT NULL AS trashed) t
        WHERE v.organization_id = ?
      SQL
    end
  end
end
