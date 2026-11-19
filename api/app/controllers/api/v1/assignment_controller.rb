module Api
  module V1
    class AssignmentController < BaseController
      include RecordsActivity
      before_action :require_organization!

      # spec 5.2.1, A8.1
      def update_assignees
        conversation = visible_conversations.find_by!(key: params[:id])
        member_ids = params[:member_ids] || []

        memberships = current_organization.memberships.where(key: member_ids, status: Membership::STATUS_ACTIVE)
        conversation.assignees = memberships
        # The actor performing the assignment gets the "Assigned" tally.
        record_activity(ActivityEvent::ACTION_ASSIGNED, conversation: conversation) if memberships.any?

        render json: {
          conversation_id: conversation.key,
          assignees: memberships.includes(:user, mailboxes: :domain).map { |m| MembershipSerializer.new(m).to_h }
        }
      end

      # spec 5.2.3, A8.2
      def remove_assignee
        conversation = visible_conversations.find_by!(key: params[:id])
        membership = current_organization.memberships.find_by!(key: params[:member_id])

        conversation.conversation_assignees.where(membership: membership).destroy_all

        head :no_content
      end

      # spec 5.3.1, A8.3
      def update_access
        conversation = visible_conversations.find_by!(key: params[:id])
        member_ids = params[:member_ids] || []

        memberships = current_organization.memberships.where(key: member_ids, status: Membership::STATUS_ACTIVE)
        conversation.accessible_members = memberships

        render json: {
          conversation_id: conversation.key,
          access: memberships.includes(:user, mailboxes: :domain).map { |m| MembershipSerializer.new(m).to_h }
        }
      end

      # spec 5.3.3, A8.4
      def remove_access
        conversation = visible_conversations.find_by!(key: params[:id])
        membership = current_organization.memberships.find_by!(key: params[:member_id])

        conversation.conversation_accesses.where(membership: membership).destroy_all

        head :no_content
      end
    end
  end
end
