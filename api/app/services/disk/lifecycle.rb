module Disk
  # Plan loss and quota warnings (spec F8). The state itself is
  # Organization#disk_state; this tells people about it and purges at the end.
  module Lifecycle
    QUOTA_LEVELS = [100, 80].freeze

    module_function

    # Owners hear about a downgrade on the day it is noticed, at day 23 and at day 83.
    def notify_owners(org, day)
      read_only_until = (org.disk_lost_at + Organization::DISK_READ_ONLY_DAYS.days).to_date
      purge_on = (org.disk_lost_at + Organization::DISK_PURGE_DAYS.days).to_date
      title, body = case day
      when 0 then ["Disk is read-only on your new plan",
                   "You can view and download files until #{read_only_until}. After that Disk closes. On #{purge_on} " \
                   "we delete its files. Upgrade before then to keep everything."]
      when 23 then ["Disk closes in 7 days",
                    "From #{read_only_until} nobody can open Disk files on this plan. Download what you need or upgrade."]
      else ["We delete your Disk files in 7 days",
            "On #{purge_on} we delete every Disk file of #{org.name}. Upgrade before then to keep them."]
      end
      org.owner_memberships.active.includes(:user).find_each do |m|
        Disk::ShareNotifier.notify(m, kind: Notification::KIND_DISK_PLAN, title: title, body: body, path: disk_path(org))
      end
    end

    # Tells owners and admins once when usage crosses 80 and 100 percent of the
    # pool; the level resets when usage falls back under 80.
    def check_quota!(organization_id)
      org = Organization.find_by(id: organization_id)
      return unless org&.disk_enabled?

      quota = Disk::Quota.new(org)
      pct = quota.pool_bytes.zero? ? (quota.used_bytes.positive? ? 100 : 0) : quota.used_bytes * 100.0 / quota.pool_bytes
      level = QUOTA_LEVELS.find { |l| pct >= l } || 0
      was = org.disk_quota_notified_level
      return if level == was || (level.positive? && level < was)
      return unless Organization.where(id: org.id, disk_quota_notified_level: was)
                                .update_all(disk_quota_notified_level: level) == 1
      return if level.zero?

      title = level == 100 ? "Disk is full" : "Disk is #{level}% full"
      body = "#{org.name} uses #{Disk::Quota.fmt(quota.used_bytes)} of #{Disk::Quota.fmt(quota.pool_bytes)}." +
             (level == 100 ? " You can't upload new files until you free some space." : "")
      org.memberships.where(status: Membership::STATUS_ACTIVE, role: Membership::ADMIN_ROLES,
                            member_type: Membership::TYPE_HUMAN).includes(:user).find_each do |m|
        Disk::ShareNotifier.notify(m, kind: Notification::KIND_DISK_QUOTA, title: title, body: body, path: disk_path(org))
      end
    end

    # Deletes every Disk row and object of the org (day 90 of a downgrade).
    def purge!(org)
      Disk::Upload.where(organization_id: org.id).active.find_each { |u| Disk::UploadOps.abort!(u) }
      Disk::Node.transaction do
        Disk::Version.release!(Disk::Version.where(organization_id: org.id))
        Disk::Link.where(organization_id: org.id).delete_all
        Disk::Event.where(organization_id: org.id).delete_all
        Disk::Share.where(organization_id: org.id).update_all(root_node_id: nil)
        Disk::Node.where(organization_id: org.id).delete_all
        Disk::Share.where(organization_id: org.id).delete_all
        Disk::Upload.where(organization_id: org.id).delete_all
        org.update_columns(disk_lost_at: nil, disk_bytes_used: 0, disk_bytes_reserved: 0, disk_quota_notified_level: 0)
      end
    end

    def disk_path(org) = Disk::WebPath.org_home(org.slug.presence || org.key)
  end
end
