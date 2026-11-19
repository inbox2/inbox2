module Saas
  # Data-usage report for one org: record counts + attachment storage bytes.
  class OrganizationUsageSerializer < ::ApplicationSerializer
    attribute :mailboxes do |org|
      org.mailbox_count
    end

    attribute :members_total do |org|
      org.memberships.count
    end

    attribute :conversations do |org|
      org.conversations.count
    end

    attribute :messages do |org|
      org.messages.count
    end

    attribute :attachments do |org|
      org.attachments.count
    end

    attribute :storage_bytes do |org|
      org.attachments.sum(:size_bytes)
    end

    attribute :effective_mailbox_limit do |org|
      org.effective_mailbox_limit
    end

    attribute :plan do |org|
      org.effective_plan.name
    end

    # Disk (spec F11): the meter and the override SaaS ops can set.
    attribute :disk do |org|
      quota = Disk::Quota.new(org)
      { enabled: org.disk_enabled?, state: org.disk_state.to_s, lost_at: org.disk_lost_at,
        used_bytes: quota.used_bytes, reserved_bytes: quota.reserved_bytes, quota_bytes: quota.pool_bytes,
        quota_override_gb: org.disk_quota_override_gb, links_enabled: org.disk_links_enabled }
    end
  end
end
