module Api
  module V1
    class OrgManagementController < BaseController
      before_action :require_organization!, except: :list_orgs

      # Alias domains (spec 2.2.5) are ordinary domains now: domains#create/destroy,
      # which also enforce the plan's domain cap. The org itself is deleted via
      # organizations#destroy. Both duplicates were removed 2026-10-18.

      # spec 2.2.7, A2.4 — Organization list for switcher
      def list_orgs
        # Preload what OrganizationSerializer reads (default_domain → :domains,
        # effective_plan → :subscription) — this is the org switcher, hit on
        # nearly every app load.
        orgs = current_user.accessible_organizations.includes(:domains, :subscription)
        memberships = current_user.memberships.includes(:membership_domains).index_by(&:organization_id)
        render json: { organizations: orgs.map { |o| OrganizationSerializer.new(o, params: { membership: memberships[o.id] }).to_h } }
      end

      # spec 2.2.6, A3.10 — Transfer org ownership
      def transfer_ownership
        require_role!(Membership::ROLE_OWNER)

        # Multi-owner: promote the target to owner and make them the *primary*
        # owner (owner_id). Existing owners keep their owner role — transferring
        # primary no longer demotes anyone.
        new_owner_membership = current_organization.memberships.find_by!(key: params[:member_id], status: Membership::STATUS_ACTIVE)
        new_owner_membership.update!(role: Membership::ROLE_OWNER)
        current_organization.update!(owner: new_owner_membership.user)

        render json: { message: "Ownership transferred" }
      end

      # Domain health (spec 2.3.6) is served for real by dns#show; the stub here
      # that answered "healthy" four times regardless was removed 2026-10-18.

      # spec 4.3.4, A6.9 — Activity log timeline
      def activity
        conversation = visible_conversations.find_by!(key: params[:id])
        events = conversation.activity_events.recent.limit(50)
        render json: { activity: events.map { |e| ActivityEventSerializer.new(e).to_h } }
      end
    end
  end
end
