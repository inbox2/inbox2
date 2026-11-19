module Api
  module V1
    # Provider webhook receivers for cloud push. Unauthenticated by design (providers
    # can't carry our session token) — verified instead via OIDC/shared-token (Gmail) and
    # validationToken + clientState (Microsoft). Inherits ApplicationController (NOT
    # BaseController) so there is no authenticate_user! / org scope. The payload is treated
    # as a content-free trigger only. See docs/Cloud-Push.md.
    class PushWebhooksController < ApplicationController
      # POST /api/v1/push/gmail — Cloud Pub/Sub push delivery.
      # Body: { message: { data: base64(JSON {emailAddress, historyId}) }, subscription: ... }
      def gmail
        return head :unauthorized unless GmailPushVerifier.verify(request)

        data = params.dig(:message, :data)
        if data.present?
          decoded = decode_gmail_data(data)
          email = decoded["emailAddress"]
          history_id = decoded["historyId"]

          if email.present?
            ChannelPushSubscription.active
              .where(provider: ChannelPushSubscription::PROVIDER_GMAIL, external_email: email)
              .find_each { |sub| ChannelPushBroadcaster.call(sub, history_id: history_id) }
          end
        end

        head :ok
      end

      # POST /api/v1/push/microsoft — Microsoft Graph change/lifecycle notifications.
      def microsoft
        # Subscription-creation handshake: echo the validationToken as text/plain.
        if params[:validationToken].present?
          return render plain: params[:validationToken], content_type: "text/plain", status: :ok
        end

        Array(params[:value]).each do |note|
          sub = ChannelPushSubscription.active.find_by(
            provider: ChannelPushSubscription::PROVIDER_MICROSOFT,
            provider_subscription_id: note[:subscriptionId]
          )
          next unless sub
          next unless valid_client_state?(note[:clientState], sub.client_state)

          ChannelPushBroadcaster.call(sub)
        end

        head :ok
      end

      private

      def decode_gmail_data(data)
        JSON.parse(Base64.decode64(data))
      rescue JSON::ParserError
        {}
      end

      def valid_client_state?(provided, expected)
        ActiveSupport::SecurityUtils.secure_compare(provided.to_s, expected.to_s)
      end
    end
  end
end
