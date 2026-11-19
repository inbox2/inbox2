module Api
  module V1
    class IntegrationsController < BaseController
      before_action :require_organization!

      # spec 14.6 — Native integrations
      def index
        integrations = current_organization.integrations
        render json: { integrations: integrations.map { |i| IntegrationSerializer.new(i).to_h } }
      end

      def show
        integration = current_organization.integrations.find_by!(key: params[:id])
        render json: { integration: IntegrationSerializer.new(integration).to_h }
      end

      def create
        require_role!(*Membership::ADMIN_ROLES)

        integration = current_organization.integrations.build(integration_params)
        if integration.save
          render json: { integration: IntegrationSerializer.new(integration).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(integration.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        require_role!(*Membership::ADMIN_ROLES)

        integration = current_organization.integrations.find_by!(key: params[:id])
        attrs = integration_params
        # Preserve unchanged secrets the client echoed back as the redaction mask.
        attrs[:config] = integration.merge_config(attrs[:config].to_h) if attrs.key?(:config)
        if integration.update(attrs)
          render json: { integration: IntegrationSerializer.new(integration).to_h }
        else
          render json: ErrorSerializer.serialize(integration.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        integration = current_organization.integrations.find_by!(key: params[:id])
        integration.destroy!
        head :no_content
      end

      private

      def integration_params
        params.permit(:name, :provider, :status, events: [], config: {})
      end
    end
  end
end
