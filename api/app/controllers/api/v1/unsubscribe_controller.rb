module Api
  module V1
    # spec 18.4.2 — List-Unsubscribe one-click handler
    class UnsubscribeController < BaseController
      skip_before_action :authenticate_user!

      def process_unsubscribe
        result = ListUnsubscribeService.process_unsubscribe(params[:token])

        if result
          render json: { status: "unsubscribed", **result }
        else
          render json: ErrorSerializer.serialize("Invalid or expired unsubscribe token", status: 422),
            status: :unprocessable_content
        end
      end
    end
  end
end
