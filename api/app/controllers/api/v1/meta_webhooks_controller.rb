module Api
  module V1
    # Meta webhook receiver (Instagram / Messenger / WhatsApp). Unauthenticated by
    # design — Meta can't carry our session token. The GET handshake is verified by a
    # shared verify token; per-tenant authenticity is the X-Hub-Signature-256 HMAC,
    # which is verified ON-DEVICE against the customer's app_secret (never held here).
    #
    # Inherits ApplicationController (NOT BaseController) — no authenticate_user! / org
    # scope. The relay does no normalization and stores no Meta secret: it buffers the
    # byte-exact raw payload + signature header, routes by asset id to the owning user,
    # and fans out a nudge carrying the buffer key. See docs/Cloud-Push.md (Meta).
    class MetaWebhooksController < ApplicationController
      # GET /api/v1/push/meta — subscription verification handshake.
      # Echoes hub.challenge when hub.verify_token matches our configured token.
      def verify
        expected = MetaConfig.verify_token
        provided = params["hub.verify_token"] || params.dig(:hub, :verify_token)
        challenge = params["hub.challenge"] || params.dig(:hub, :challenge)

        if expected.nil? || (provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided.to_s, expected))
          render plain: challenge.to_s, status: :ok
        else
          head :forbidden
        end
      end

      # POST /api/v1/push/meta — inbound event.
      # Buffer the raw body, route to the owning user, fan out a nudge. Always 200 fast
      # (Meta retries on non-2xx); unroutable/duplicate events are silently accepted.
      def receive
        raw = request.raw_post.to_s
        signature = request.headers["X-Hub-Signature-256"]
        object = params[:object].to_s

        user = resolve_owner(object)
        return head :ok unless user # unknown asset — accept + drop

        event_id = "sha256:#{Digest::SHA256.hexdigest(raw)}"
        # Dedup Meta retries (identical body → identical hash). find_or_create avoids a
        # race where two retries arrive concurrently.
        event = MetaWebhookEvent.find_or_initialize_by(provider_event_id: event_id)
        if event.new_record?
          event.assign_attributes(
            user: user,
            object: object,
            asset_id: @matched_asset_id,
            raw_payload: raw,
            signature_header: signature,
            received_at: Time.current
          )
          event.save!
          MetaWebhookBroadcaster.call(event)
        end

        head :ok
      rescue ActiveRecord::RecordNotUnique
        # Concurrent retry won the insert — already buffered + broadcast.
        head :ok
      rescue => e
        Rails.logger.warn("[MetaWebhooksController] receive error: #{e.message}")
        head :ok
      end

      private

      # Find the owning user from the payload's asset ids. WhatsApp prefers the
      # phone-number id (most specific), then WABA; Page/Instagram use entry[].id.
      # Sets @matched_asset_id as a side effect for buffering.
      def resolve_owner(object)
        candidates(object).each do |asset_type, asset_id|
          next if asset_id.blank?
          user = MetaChannelSubscription.owner_for(asset_type: asset_type, asset_id: asset_id)
          if user
            @matched_asset_id = asset_id
            return user
          end
        end
        nil
      end

      # [[asset_type, asset_id], ...] in routing-priority order.
      def candidates(object)
        out = []
        Array(params[:entry]).each do |entry|
          case object
          when "page"
            out << [MetaChannelSubscription::ASSET_PAGE, entry[:id]]
          when "instagram"
            out << [MetaChannelSubscription::ASSET_INSTAGRAM, entry[:id]]
          when "whatsapp_business_account"
            Array(entry[:changes]).each do |change|
              phone = change.dig(:value, :metadata, :phone_number_id)
              out << [MetaChannelSubscription::ASSET_PHONE, phone] if phone.present?
            end
            out << [MetaChannelSubscription::ASSET_WABA, entry[:id]]
          end
        end
        out
      end
    end
  end
end
