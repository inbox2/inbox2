module Api
  module V1
    # Device fetch + ack of buffered Meta webhook payloads. Authenticated and scoped to
    # current_user (E3 tenant isolation — another user's event resolves to 404). The
    # device fetches the byte-exact raw body + signature, verifies the HMAC against its
    # locally-held app_secret, normalizes, then acks. See docs/Cloud-Push.md (Meta).
    class MetaWebhookEventsController < BaseController
      # GET /api/v1/meta-webhook-events/:id
      def show
        event = current_user.meta_webhook_events.fresh.find_by_key!(params[:id])
        render json: { event: MetaWebhookEventSerializer.new(event).to_h }
      end

      # DELETE /api/v1/meta-webhook-events/:id — ack. Idempotent: marks consumed (rather
      # than hard-deleting) so a user's other devices can still fetch within the TTL; the
      # sweeper GCs it. A missing/expired row is a no-op success.
      def destroy
        event = current_user.meta_webhook_events.find_by(key: params[:id])
        event&.update_column(:consumed_at, Time.current)
        head :no_content
      end
    end
  end
end
