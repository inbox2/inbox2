module Api
  module V1
    class WidgetsController < BaseController
      before_action :require_organization!, except: [:public_config]
      skip_before_action :authenticate_user!, only: [:public_config]

      # spec 14.7 — Embeddable widgets
      def index
        widgets = current_organization.widget_configs
        render json: { widgets: widgets.map { |w| WidgetConfigSerializer.new(w).to_h } }
      end

      def create
        require_role!(*Membership::ADMIN_ROLES)

        widget = current_organization.widget_configs.build(widget_params)
        if widget.save
          render json: { widget: WidgetConfigSerializer.new(widget).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(widget.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        require_role!(*Membership::ADMIN_ROLES)

        widget = current_organization.widget_configs.find_by!(key: params[:id])
        if widget.update(widget_params)
          render json: { widget: WidgetConfigSerializer.new(widget).to_h }
        else
          render json: ErrorSerializer.serialize(widget.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        widget = current_organization.widget_configs.find_by!(key: params[:id])
        widget.destroy!
        head :no_content
      end

      # Public endpoint — no auth required, used by embedded widget JS
      def public_config
        widget = WidgetConfig.find_by(widget_token: params[:token], status: WidgetConfig::STATUS_ACTIVE)

        # Return 404 for both missing token and domain mismatch to prevent probing
        origin = request.headers["Origin"] || ""
        unless widget&.domain_allowed?(origin)
          return render json: ErrorSerializer.serialize("Not found", status: 404), status: :not_found
        end

        render json: {
          organization: widget.organization.name,
          appearance: widget.appearance,
          behavior: widget.behavior
        }
      end

      private

      def widget_params
        params.permit(:name, :status, :allowed_domains, appearance: {}, behavior: {})
      end
    end
  end
end
