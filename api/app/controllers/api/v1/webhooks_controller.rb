module Api
  module V1
    class WebhooksController < BaseController
      before_action :require_organization!

      # spec 7.3.5, A11.6
      def index
        webhooks = current_organization.webhooks
        render json: { webhooks: webhooks.map { |w| WebhookSerializer.new(w).to_h } }
      end

      def create
        require_role!(*Membership::ADMIN_ROLES)

        webhook = current_organization.webhooks.build(webhook_params)
        if webhook.save
          render json: { webhook: WebhookSerializer.new(webhook).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(webhook.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def update
        require_role!(*Membership::ADMIN_ROLES)

        webhook = current_organization.webhooks.find_by!(key: params[:id])
        if webhook.update(webhook_params)
          render json: { webhook: WebhookSerializer.new(webhook).to_h }
        else
          render json: ErrorSerializer.serialize(webhook.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        webhook = current_organization.webhooks.find_by!(key: params[:id])
        webhook.destroy!
        head :no_content
      end

      private

      def webhook_params
        params.permit(:url, :secret, :enabled, events: [], payload_template: {})
      end
    end
  end
end
