module Api
  module V1
    class CalendarsController < BaseController
      before_action :require_organization!

      # GET /api/v1/orgs/:org_id/calendars
      def index
        # Nothing else provisions a calendar, so a brand-new member would get an
        # empty list, an empty calendar screen, and a 404 on their first event.
        Calendar.primary_for(current_organization, current_membership)

        calendars = current_organization.calendars
          .for_member(current_membership)
          .order(:name)

        render json: { calendars: calendars.map { |c| CalendarSerializer.new(c).to_h } }
      end

      # GET /api/v1/orgs/:org_id/calendars/:id
      def show
        calendar = find_calendar!
        render json: { calendar: CalendarSerializer.new(calendar).to_h }
      end

      # POST /api/v1/orgs/:org_id/calendars
      def create
        calendar = current_organization.calendars.build(calendar_params)
        calendar.membership = current_membership if calendar.membership_id.blank?

        if calendar.save
          render json: { calendar: CalendarSerializer.new(calendar).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(calendar.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # PATCH /api/v1/orgs/:org_id/calendars/:id
      def update
        calendar = find_calendar!

        if calendar.update(calendar_update_params)
          render json: { calendar: CalendarSerializer.new(calendar).to_h }
        else
          render json: ErrorSerializer.serialize(calendar.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # DELETE /api/v1/orgs/:org_id/calendars/:id
      def destroy
        calendar = find_calendar!
        calendar.destroy!
        head :no_content
      end

      private

      def find_calendar!
        current_organization.calendars
          .for_member(current_membership)
          .find_by!(key: params[:id])
      end

      def current_membership
        @current_membership ||= current_organization.memberships.find_by!(user: current_user)
      end

      def calendar_params
        params.permit(:name, :description, :color, :is_primary, :is_visible)
      end

      def calendar_update_params
        params.permit(:name, :description, :color, :is_visible)
      end
    end
  end
end
