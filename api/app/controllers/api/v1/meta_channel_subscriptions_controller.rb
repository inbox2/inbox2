module Api
  module V1
    # Meta channels (Instagram/Messenger/WhatsApp) — device-reported asset→user routing.
    # Per-user (personal connections), scoped to current_user. Stores only the mapping
    # between a Meta asset and a user — never the app secret or System User token. The
    # device subscribes its own app's webhooks; this only records routing. See
    # docs/Cloud-Push.md (Meta).
    class MetaChannelSubscriptionsController < BaseController
      # GET /api/v1/meta-channel-subscriptions
      def index
        subs = current_user.meta_channel_subscriptions.active
        render json: {
          push_enabled: current_user.push_enabled?,
          subscriptions: subs.map { |s| MetaChannelSubscriptionSerializer.new(s).to_h }
        }
      end

      # POST /api/v1/meta-channel-subscriptions
      # Idempotent upsert on the (user, asset_type, asset_id) unique index; gated by
      # push_enabled? and lease-bumped so any device can (re)register.
      def create
        return forbidden_push unless current_user.push_enabled?

        sub = current_user.meta_channel_subscriptions.find_or_initialize_by(
          asset_type: params[:asset_type],
          asset_id: params[:asset_id]
        )
        sub.channel = params[:channel]
        renew_lease(sub)

        if sub.save
          render json: { subscription: MetaChannelSubscriptionSerializer.new(sub).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(sub.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # DELETE /api/v1/meta-channel-subscriptions/:id
      def destroy
        sub = current_user.meta_channel_subscriptions.find_by_key!(params[:id])
        sub.destroy!
        head :no_content
      end

      # GET /api/v1/meta-channel-subscriptions/config
      # The verify token + gating the client needs to auto-configure the customer
      # app's webhook on connect (POST /{app_id}/subscriptions). The verify token
      # is the shared GET-handshake token (not a per-tenant secret); nil when
      # unset on the deployment (the relay then accepts any token).
      # NB: not named `config` — that overrides ActionController#config.
      def meta_config
        render json: {
          push_enabled: current_user.push_enabled?,
          verify_token: MetaConfig.verify_token
        }
      end

      private

      def renew_lease(sub)
        sub.status = MetaChannelSubscription::STATUS_ACTIVE
        sub.last_seen_at = Time.current
        sub.lease_expires_at = MetaChannelSubscription::LEASE_DURATION.from_now
      end

      def forbidden_push
        render json: ErrorSerializer.serialize("Push not enabled for this account", status: 403), status: :forbidden
      end
    end
  end
end
