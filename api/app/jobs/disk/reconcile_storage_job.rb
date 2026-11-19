module Disk
  # Squares the bucket with disk_versions and disk_uploads (build guide section
  # 8). Finishes uploads left in completing whose object exists and aborts
  # those whose object does not. Reports, without deleting, objects and open
  # multipart uploads nothing points at, and orgs whose used or reserved
  # figures disagree with their rows. Daily.
  class ReconcileStorageJob < ApplicationJob
    queue_as :default

    STUCK_AFTER = 1.hour # a completing upload younger than this may still be finishing
    ORPHAN_AFTER = 1.day # an unknown object younger than this may be mid-upload

    def perform(now: Time.current)
      finished = aborted = 0
      Disk::Upload.where(state: Disk::Upload::STATE_COMPLETING).where(updated_at: ..(now - STUCK_AFTER)).find_each do |u|
        Disk::UploadOps.finish!(u)
        finished += 1
      rescue Disk::Refused => e
        aborted += 1
        Rails.logger.warn("[Disk::ReconcileStorageJob] aborted #{u.key}: #{e.message}")
      end
      report = { finished: finished, aborted: aborted, **orphans(now), quota_drift: quota_drift }
      Rails.logger.info("[Disk::ReconcileStorageJob] #{report.to_json}")
      report
    end

    private

    # ponytail: holds every known key in memory; page by org prefix past a few million objects.
    def orphans(now)
      storage = Disk::Storage.current
      known = Set.new(Disk::Upload.active.pluck(:storage_key))
      Disk::Version.pluck(:storage_key, :thumbnail_storage_key, :rendition_storage_key).each { |keys| known.merge(keys.compact) }
      objects = []
      storage.each_object { |key, _size, at| objects << key if at < now - ORPHAN_AFTER && !known.include?(key) }
      open_ids = Set.new(Disk::Upload.active.where.not(multipart_upload_id: nil).pluck(:multipart_upload_id))
      multiparts = storage.open_multiparts.reject { |_key, id, at| open_ids.include?(id) || at > now - ORPHAN_AFTER }
      { orphan_objects: objects, orphan_multiparts: multiparts.map(&:first) }
    end

    # { org key => { used: [recorded, actual], reserved: [recorded, actual] } } where they differ.
    def quota_drift
      versions = Disk::Version.group(:organization_id).sum(:size_bytes)
      uploads = Disk::Upload.active.group(:organization_id).sum(:declared_bytes)
      Organization.where("disk_bytes_used <> 0 OR disk_bytes_reserved <> 0").or(Organization.where(id: versions.keys + uploads.keys))
        .pluck(:id, :key, :disk_bytes_used, :disk_bytes_reserved).each_with_object({}) do |(id, key, used, reserved), out|
          actual_used = versions[id].to_i
          actual_reserved = uploads[id].to_i
          next if used == actual_used && reserved == actual_reserved

          out[key] = { used: [used, actual_used], reserved: [reserved, actual_reserved] }
        end
    end
  end
end
