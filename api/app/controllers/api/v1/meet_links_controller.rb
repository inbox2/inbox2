module Api
  module V1
    # Per-member meet link management (Settings › Scheduling). Any member can
    # create links, including links that book a colleague; the invitee always
    # sees links that book them and can revoke those too — being bookable is
    # never something a colleague does *to* you silently.
    class MeetLinksController < BaseController
      before_action :require_organization!

      # GET /api/v1/orgs/:org_id/meet-links
      def index
        me = current_active_membership!
        mine = current_organization.meet_links.where(membership: me)
        booking_me = current_organization.meet_links.where(invitee_membership: me).where.not(membership: me)

        render json: {
          meet_links: mine.order(created_at: :desc).map { |l| MeetLinkSerializer.new(l).to_h },
          booking_you: booking_me.order(created_at: :desc).map { |l| MeetLinkSerializer.new(l).to_h }
        }
      end

      # POST /api/v1/orgs/:org_id/meet-links
      def create
        me = current_active_membership!
        link = current_organization.meet_links.build(link_params)
        link.membership = me
        link.invitee_membership = resolve_invitee || me
        link.save!

        render json: { meet_link: MeetLinkSerializer.new(link).to_h }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      # DELETE /api/v1/orgs/:org_id/meet-links/:id — revoke (soft; stats stay).
      def destroy
        me = current_active_membership!
        link = current_organization.meet_links
          .where(membership: me).or(current_organization.meet_links.where(invitee_membership: me))
          .find_by!(key: params[:id])
        link.revoke!

        render json: { meet_link: MeetLinkSerializer.new(link).to_h }
      end

      private

      def link_params
        params.permit(:label, :duration_minutes, :min_notice_minutes, :max_ahead_days, :conference_mode)
      end

      # The colleague this link books, by membership key. Scoped to the org so a
      # foreign key 404s (E3).
      def resolve_invitee
        return nil if params[:invitee_membership_id].blank?

        current_organization.memberships.find_by!(
          key: params[:invitee_membership_id], status: Membership::STATUS_ACTIVE
        )
      end
    end
  end
end
