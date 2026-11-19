module Api
  module V1
    # Cloud push for local channels (Gmail/Office365). Per-user (personal mailboxes),
    # so scoped to current_user rather than an org. Stores only the mapping between a
    # provider-side subscription and a user — never the OAuth token. See docs/Cloud-Push.md.
    class ChannelPushSubscriptionsController < BaseController
      # GET /api/v1/channel-push-subscriptions?email=...&provider=...
      # The client's "does the backend already have a subscription?" check.
      def index
        # `provider_live` excludes rows whose provider-side subscription has lapsed
        # (expires_at past) even if the 30d Rails lease is still valid — so the client
        # re-registers instead of trusting a stale lease and leaving push dead.
        subs = current_user.channel_push_subscriptions.active.provider_live
        subs = subs.where(external_email: params[:email]) if params[:email].present?
        subs = subs.where(provider: params[:provider]) if params[:provider].present?

        render json: {
          push_enabled: current_user.push_enabled?,
          subscriptions: subs.map { |s| ChannelPushSubscriptionSerializer.new(s).to_h }
        }
      end

      # POST /api/v1/channel-push-subscriptions
      # Client reports a provider sub it just created (mapping only). Gated + idempotent
      # on the (user, provider, email) unique index so any device can (re)register.
      def create
        return forbidden_push unless current_user.push_enabled?

        sub = current_user.channel_push_subscriptions.find_or_initialize_by(
          provider: params[:provider],
          external_email: params[:external_email]
        )
        sub.assign_attributes(sub_params)
        renew_lease(sub)

        if sub.save
          render json: { subscription: ChannelPushSubscriptionSerializer.new(sub).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(sub.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # PATCH/PUT /api/v1/channel-push-subscriptions/:id
      # Renewal — refresh provider expiry and bump the Rails-side lease.
      def update
        sub = current_user.channel_push_subscriptions.find_by_key!(params[:id])
        sub.assign_attributes(sub_params.compact)
        renew_lease(sub)

        if sub.save
          render json: { subscription: ChannelPushSubscriptionSerializer.new(sub).to_h }
        else
          render json: ErrorSerializer.serialize(sub.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # DELETE /api/v1/channel-push-subscriptions/:id
      def destroy
        sub = current_user.channel_push_subscriptions.find_by_key!(params[:id])
        sub.destroy!
        head :no_content
      end

      # GET /api/v1/channel-push-subscriptions/config
      # Engine fetches the topic name + webhook base needed to create provider subscriptions.
      # NB: not named `config` — that overrides ActionController#config (used internally).
      def push_config
        render json: {
          push_enabled: current_user.push_enabled?,
          configured: PushConfig.configured?,
          webhook_base_url: PushConfig.webhook_base_url,
          gmail_topic: PushConfig.gmail_topic,
          gmail_webhook_path: PushConfig::GMAIL_WEBHOOK_PATH,
          microsoft_notification_url: PushConfig.microsoft_notification_url
        }
      end

      private

      def sub_params
        params.permit(:provider, :external_email, :provider_subscription_id, :client_state, :expires_at)
      end

      def renew_lease(sub)
        sub.status = ChannelPushSubscription::STATUS_ACTIVE
        sub.last_seen_at = Time.current
        sub.lease_expires_at = ChannelPushSubscription::LEASE_DURATION.from_now
      end

      def forbidden_push
        render json: ErrorSerializer.serialize("Push not enabled for this account", status: 403), status: :forbidden
      end
    end
  end
end
