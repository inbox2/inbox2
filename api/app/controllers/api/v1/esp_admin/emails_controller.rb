module Api
  module V1
    module EspAdmin
      # The send log and this month's use of the allowance.
      class EmailsController < BaseController
        def index
          scope = current_organization.esp_messages.includes(:deliveries).order(id: :desc)
          scope = scope.where(tag: params[:tag]) if params[:tag].present?
          if ::Esp::Delivery::STATUSES.include?(params[:status])
            scope = scope.where(id: current_organization.esp_deliveries.where(status: params[:status]).select(:esp_message_id))
          end
          records, meta = paginate(scope, default_per_page: 25, max_per_page: 100)
          render json: { emails: records.without_body.map { |m| EspEmailSerializer.new(m).to_h }, meta: meta }
        end

        def show
          message = current_organization.esp_messages.without_body.find_by!(key: params[:id])
          render json: { email: EspEmailSerializer.new(message, params: { events: true }).to_h }
        end

        def usage
          month = Time.current.beginning_of_month
          render json: { usage: {
            allowance: current_organization.effective_plan.esp_monthly_sends,
            used: current_organization.esp_deliveries.where(created_at: month..).count,
            period_start: month.iso8601
          } }
        end
      end
    end
  end
end
