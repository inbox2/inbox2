module Disk
  # Releases uploads abandoned past their expiry: the reservation goes back to
  # the quota and storage drops the parts (spec F2: within a day). Also ends
  # what sealing's staged moves left behind (build guide 6.8): staged nodes
  # never switched in, and switched sources whose purge did not finish. Hourly.
  class ExpireUploadsJob < ApplicationJob
    queue_as :default

    def perform(now: Time.current)
      expired = Disk::Upload.where(state: Disk::Upload::STATE_RESERVED).where(expires_at: ..now)
      count = 0
      expired.find_each do |upload|
        Disk::UploadOps.abort!(upload, states: [Disk::Upload::STATE_RESERVED]) # a completion since wins
        count += 1 if upload.aborted?
      end
      Disk::Node.where(pending_until: ..now).find_each do |node|
        Disk::Node.transaction do
          Disk::Node.add_size!(node.parent, -node.size_bytes)
          Disk::NodeOps.purge!(node)
        end
      end
      Disk::Node.where.not(switched_at: nil).find_each { |node| Disk::NodeOps.purge_switched!(node) }
      Rails.logger.info("[Disk::ExpireUploadsJob] released #{count} abandoned upload(s)") if count.positive?
      count
    end
  end
end
