module Api
  module V1
    # Team activity board — per-member action tallies (Replied/Deleted/Archived/
    # Read/Snoozed/Assigned) over a rolling window, plus a per-member action feed.
    #
    # ponytail: read-only aggregate. It returns zeros until the conversation action
    # paths log ActivityEvents with `membership:` (write-path instrumentation is the
    # deferred telemetry follow-up). The in-Ruby daily bucketing is fine at current
    # volumes — move to a SQL date_trunc GROUP BY if event counts grow large.
    class MemberActivityController < BaseController
      before_action :require_organization!

      WINDOW_DAYS = 14

      # GET /orgs/:org_id/members/activity — summary card per active member.
      def index
        # Insights switched off (owner/admin choice) → surface nothing, not even
        # events logged while it was on.
        unless current_organization.activity_tracking_enabled?
          return render json: { tracking_enabled: false, range: { days: WINDOW_DAYS }, activity: [] }
        end

        since = Time.current.to_date - (WINDOW_DAYS - 1) # last WINDOW_DAYS days, including today
        rows = current_organization.activity_events
          .where(action: ActivityEvent::METRIC_ACTIONS)
          .where(created_at: since.beginning_of_day..)
          .where.not(membership_id: nil)
          .pluck(:membership_id, :action, :created_at)

        totals = Hash.new { |h, k| h[k] = Hash.new(0) } # totals[membership_id][action]
        daily  = Hash.new { |h, k| h[k] = Hash.new(0) } # daily[membership_id][date]  = count
        rows.each do |mid, action, at|
          totals[mid][action] += 1
          daily[mid][at.to_date] += 1
        end

        dates = (0...WINDOW_DAYS).map { |i| since + i }
        memberships = current_active_membership!.teammates
          .where(status: Membership::STATUS_ACTIVE).includes(:user)

        render json: {
          tracking_enabled: true,
          range: { days: WINDOW_DAYS },
          activity: memberships.map { |m|
            MemberActivitySerializer.new(
              m,
              params: { totals: totals[m.id], daily: daily[m.id], dates: dates, avatar_org_key: current_organization.key }
            ).to_h
          }
        }
      end

      # GET /orgs/:org_id/members/:id/activity — one member's action feed.
      def show
        membership = current_organization.memberships.find_by!(key: params[:id])
        # The feed carries conversation subjects from any domain: admins or yourself only.
        unless current_membership&.admin? || membership == current_membership
          return render json: ErrorSerializer.serialize("Forbidden", status: 403), status: :forbidden
        end
        events = current_organization.activity_events.where(membership_id: membership.id)
        # A member reading their own feed sees only threads they can still see
        # (access may have been revoked since).
        unless current_membership&.all_domains_access?
          events = events.where(conversation_id: nil).or(events.where(conversation_id: visible_conversations.select(:id)))
        end
        events = events.recent.limit(100).includes(:conversation)

        render json: {
          member: MembershipSerializer.new(membership, params: { avatar_org_key: current_organization.key }).to_h,
          feed: events.map { |e| MemberActivityEventSerializer.new(e).to_h }
        }
      end
    end
  end
end
