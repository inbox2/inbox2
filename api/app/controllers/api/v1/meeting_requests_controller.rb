module Api
  module V1
    # Accept/decline for meet-link requests (docs/Calendar.md). Invitee-only:
    # it's their calendar, so it's their decision — even the link's creator
    # can't answer for them. Cross-tenant lookups 404 (E3); a member who isn't
    # the invitee gets 403.
    class MeetingRequestsController < BaseController
      before_action :require_organization!

      # POST /api/v1/orgs/:org_id/meeting-requests/:id/accept
      def accept
        request_row = find_request!
        return unless require_invitee!(request_row)
        return unless require_pending!(request_row)

        result = MeetingRequestDecision.accept(request_row, current_active_membership!)
        return already_answered(request_row) if result.nil?

        render json: {
          request: MeetingRequestSerializer.new(request_row.reload).to_h,
          event: CalendarEventSerializer.new(result.event).to_h,
          conflict: result.conflict,
          conference_error: result.conference_error
        }
      end

      # POST /api/v1/orgs/:org_id/meeting-requests/:id/decline
      def decline
        request_row = find_request!
        return unless require_invitee!(request_row)
        return unless require_pending!(request_row)

        result = MeetingRequestDecision.decline(request_row, current_active_membership!, reason: params[:reason])
        return already_answered(request_row) if result.nil?

        render json: { request: MeetingRequestSerializer.new(request_row.reload).to_h }
      end

      private

      def find_request!
        MeetingRequest.where(organization: current_organization).find_by!(key: params[:id])
      end

      def require_invitee!(request_row)
        if request_row.meet_link.invitee_membership_id == current_active_membership!.id
          return true
        end

        render json: ErrorSerializer.serialize("Only the person being booked can answer this request", status: 403),
          status: :forbidden
        false
      end

      # A decision that lost the row-lock race to a concurrent one.
      def already_answered(request_row)
        render json: ErrorSerializer.serialize("This request was already #{request_row.reload.status}", status: 422),
          status: :unprocessable_content
      end

      def require_pending!(request_row)
        return true if request_row.pending?

        render json: ErrorSerializer.serialize("This request was already #{request_row.status}", status: 422),
          status: :unprocessable_content
        false
      end
    end
  end
end
