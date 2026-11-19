module Api
  module V1
    class PushSubscriptionsController < BaseController
      # spec 10.4, A14.4 — Browser push notifications
      def create
        sub = current_user.push_subscriptions.find_or_initialize_by(endpoint: params[:endpoint])
        sub.p256dh_key = params[:p256dh_key]
        sub.auth_key = params[:auth_key]
        sub.user_agent = request.user_agent

        if sub.save
          render json: { subscribed: true }, status: :created
        else
          render json: ErrorSerializer.serialize(sub.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        sub = current_user.push_subscriptions.find_by(endpoint: params[:endpoint])
        sub&.destroy
        head :no_content
      end

      def vapid_public_key
        key = Rails.application.credentials.dig(:vapid, :public_key) || "not_configured"
        render json: { vapid_public_key: key }
      end
    end
  end
end
