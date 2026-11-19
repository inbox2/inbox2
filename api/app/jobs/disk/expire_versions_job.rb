module Disk
  # Deletes replaced versions once their retention (Disk::Version::RETAIN_DAYS)
  # runs out, returning their bytes to the quota. A current version never expires.
  # Page history entries older than the same retention go too, except each
  # page's newest. Daily.
  class ExpireVersionsJob < ApplicationJob
    queue_as :default

    def perform(now: Time.current)
      current = Disk::Node.where.not(current_version_id: nil).select(:current_version_id)
      count = 0
      Disk::Version.where(expires_at: ..now).where.not(id: current).in_batches(of: 500) do |batch|
        Disk::Version.transaction do
          Disk::Version.release!(batch)
          count += batch.delete_all
        end
      end
      count += expire_page_history(now)
      Rails.logger.info("[Disk::ExpireVersionsJob] expired #{count} version(s)") if count.positive?
      count
    end

    private

    def expire_page_history(now)
      newest = Disk::PageVersion.group(:node_id).select("max(id)")
      Disk::PageVersion.where(updated_at: ..(now - Disk::Version::RETAIN_DAYS.days)).where.not(id: newest).delete_all
    end
  end
end
