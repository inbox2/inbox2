module Disk
  # Daily: for every org holding Disk data, notices a lost or regained plan
  # (Organization#disk_state), sends the day-23 and day-83 warnings, purges
  # at day 90, and re-checks quota warnings (a member leaving shrinks the pool).
  class LifecycleJob < ApplicationJob
    queue_as :default

    def perform(now: Time.current)
      purged = 0
      Organization.where(id: Disk::Node.select(:organization_id)).find_each do |org|
        next Disk::Lifecycle.check_quota!(org.id) if org.disk_state(now: now) == Organization::DISK_ACTIVE

        age = ((now - org.disk_lost_at) / 1.day).floor
        Disk::Lifecycle.notify_owners(org, age) if [23, 83].include?(age)
        next unless age >= Organization::DISK_PURGE_DAYS

        Disk::Lifecycle.purge!(org)
        purged += 1
      end
      Rails.logger.info("[Disk::LifecycleJob] purged Disk for #{purged} org(s)") if purged.positive?
      purged
    end
  end
end
