module Saas
  # Account-wide operational metrics for the SaaS dashboard. Plain counts
  # (no tenant scoping) computed in aggregate SQL — safe to call across the whole
  # tenant base.
  class DashboardMetrics
    SERIES_DAYS = 7

    def initialize(now: Time.current)
      @now = now
    end

    def call
      {
        organizations: org_metrics,
        users: user_metrics,
        mailboxes: mailbox_metrics,
        plans: plan_distribution,
        mail: mail_metrics,
        disk: disk_metrics
      }
    end

    private

    def window_start
      @window_start ||= (@now.beginning_of_day - (SERIES_DAYS - 1).days)
    end

    def org_metrics
      {
        total: Organization.teams.count,
        suspended: Organization.teams.where.not(suspended_at: nil).count,
        domains_total: Domain.count,
        by_domain_status: Domain.group(:status).count,
        new_7d: Organization.teams.where("created_at >= ?", window_start).count
      }
    end

    def user_metrics
      { total: User.count, new_7d: User.where("created_at >= ?", window_start).count }
    end

    def mailbox_metrics
      {
        active: Membership.where(status: Membership::STATUS_ACTIVE).count,
        invited: Membership.where(status: Membership::STATUS_INVITED).count,
        total: Membership.count
      }
    end

    # Free vs paid by *effective* plan, in aggregate SQL: an org is paid if its
    # per-org override is a non-Free plan, or (no override) it subscribes to a
    # non-Free plan. Everything else is Free.
    def plan_distribution
      free_id = Plan.free.id
      override_paid = Organization.teams.where.not(plan_id: [nil, free_id]).count
      inherited_paid = Organization.teams.where(plan_id: nil)
        .joins("INNER JOIN subscriptions ON subscriptions.organization_id = organizations.id")
        .where.not(subscriptions: { plan_id: free_id }).count
      paid = override_paid + inherited_paid

      { paid: paid, free: Organization.teams.count - paid }
    end

    # Disk (spec Non-functional "Metrics"): bytes stored, uploads, previews by
    # type with failure rate, links created. Opens of a file (Disk::Recent rows
    # touched in the window, one per member and file) stand in for previews.
    def disk_metrics
      since = window_start
      opens = Disk::Recent.joins(:node).where(updated_at: since..).where(disk_nodes: { kind: Disk::Node::KIND_FILE })
        .group("disk_nodes.mime").count
      failures = Disk::Event.where(action: Disk::Event::ACTION_PREVIEW_FAILED, created_at: since..)
        .group(Arel.sql("detail->>'mime'")).count
      {
        bytes_stored: Organization.sum(:disk_bytes_used),
        orgs_using: Organization.where("disk_bytes_used > 0").count, # personal workspaces included: they hold the C:\ drives

        uploads_7d: Disk::Upload.where(state: Disk::Upload::STATE_DONE, updated_at: since..).count,
        links_created_7d: Disk::Event.where(action: Disk::Event::ACTION_LINK_CREATED, created_at: since..).count,
        # Import runs started in the window, by state (spec non-functional: metrics from day one).
        imports_7d: Disk::Import.where(created_at: since..).group(:state).count,
        previews_7d: (opens.keys | failures.keys).map do |mime|
          { mime: mime, opens: opens.fetch(mime, 0), failures: failures.fetch(mime, 0) }
        end
      }
    end

    def mail_metrics
      base = Message.where(is_draft: false).where("created_at >= ?", window_start)
      { inbound_7d: base.where(is_inbound: true).count, outbound_7d: base.where(is_inbound: false).count }
    end
  end
end
