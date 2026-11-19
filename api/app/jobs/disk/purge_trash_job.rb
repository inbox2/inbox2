module Disk
  # Deletes forever what has sat in the trash for Disk::TRASH_DAYS, and shares
  # whose purge_at has passed, returning their bytes to the quota and removing
  # their objects. Daily.
  class PurgeTrashJob < ApplicationJob
    queue_as :default

    def perform(now: Time.current)
      ids = Disk::Node.where(trash_root: true).where(trashed_at: ..(now - Disk::TRASH_DAYS.days)).order(:id).pluck(:id)
      nodes = 0
      ids.each do |id|
        node = Disk::Node.find_by(id: id) # an earlier purge may have taken it with its parent
        next unless node

        Disk::NodeOps.purge!(node)
        nodes += 1
      end
      shares = 0
      Disk::Share.where.not(trashed_at: nil).where(purge_at: ..now).find_each do |share|
        share.purge!
        shares += 1
      end
      Rails.logger.info("[Disk::PurgeTrashJob] purged #{nodes} item(s) and #{shares} share(s)") if (nodes + shares).positive?
      { nodes: nodes, shares: shares }
    end
  end
end
