module Api
  module V1
    # Mobile push device tokens (APNs/FCM) — see docs/Cloud-Push.md "Mobile push".
    # Per-user like channel push subscriptions. Register/deregister are keyed on
    # the raw platform token: upsert is global on token (a device that signs into
    # a different account must move with it), delete is scoped to current_user.
    class PushDevicesController < BaseController
      # POST /api/v1/push-devices
      def create
        return forbidden_push unless current_user.push_enabled?

        device = PushDevice.find_or_initialize_by(token: params[:token])
        device.user = current_user
        device.platform = params[:platform]
        device.environment = params[:environment].presence || PushDevice::ENV_PRODUCTION
        device.device_name = params[:device_name].presence
        device.last_registered_at = Time.current
        # Optional on registration; the app also reports it via #unread as it changes.
        device.channel_unread = params[:channel_unread].to_i if params.key?(:channel_unread)

        if device.save
          render json: { device: PushDeviceSerializer.new(device).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(device.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # POST /api/v1/push-devices/unread — the client reports its offline-channel
      # unread count (local SQLite; the server never sees channel mail) so a push
      # sent while the app is closed can carry an accurate app-icon badge =
      # domain/MX unread + this. User-scoped lookup by token; idempotent.
      def unread
        device = current_user.push_devices.find_by(token: params[:token])
        return head :not_found unless device

        device.update(channel_unread: params[:channel_unread].to_i)
        head :no_content
      end

      # POST /api/v1/push-devices/live-activity — ActivityKit tokens for the iOS
      # Mail Live Activity: `start_token` (push-to-start, long-lived) and
      # `activity_token` (the running activity's update token; null when it
      # ends). Each key is applied only when present, so the two can be reported
      # independently. User-scoped lookup by device token; idempotent.
      def live_activity
        device = current_user.push_devices.find_by(token: params[:token])
        return head :not_found unless device

        attrs = {}
        attrs[:live_activity_start_token] = params[:start_token].presence if params.key?(:start_token)
        attrs[:live_activity_token] = params[:activity_token].presence if params.key?(:activity_token)
        device.update(attrs) if attrs.any?
        head :no_content
      end

      # POST /api/v1/push-devices/live-activity/start — the app asks for a
      # push-to-start of its own card. iOS lets an app UPDATE a Live Activity from
      # the background but never START one, and Rails never sees channel mail, so
      # after a wake-sync finds new unread mail with no card up, the app hands the
      # content here and APNs starts the card. Content is an allow-list (E4) and
      # goes only to this device.
      LIVE_ACTIVITY_STATE_KEYS = %w[conversationKey accountKey orgId sender subject snippet].freeze

      def live_activity_start
        device = current_user.push_devices.find_by(token: params[:token])
        return head :not_found unless device

        state = params.require(:content_state).permit(*LIVE_ACTIVITY_STATE_KEYS).to_h
        MobilePushSender.live_activity(current_user, content_state: state, devices: [ device ])
        head :accepted
      end

      # POST /api/v1/push-devices/clear-notifications — a device acted on
      # local-channel mail (read/archive/trash) and asks the user's other devices
      # to drop the matching banners. `tags` are opaque hashes (docs/Cloud-Push.md
      # "Clearing channel banners"); anything else is dropped (E4).
      CLEAR_TAG = /\A[0-9a-f]{32}\z/
      CLEAR_TAGS_MAX = 100

      def clear_notifications
        tags = Array(params[:tags]).map(&:to_s).grep(CLEAR_TAG).uniq.first(CLEAR_TAGS_MAX)
        if tags.empty?
          return render json: ErrorSerializer.serialize("tags required", status: 422), status: :unprocessable_content
        end

        MobilePushSender.clear_channel_notifications(current_user, tags: tags)
        head :accepted
      end

      # DELETE /api/v1/push-devices
      # Idempotent; user-scoped lookup so one user can never remove another's device.
      def destroy
        current_user.push_devices.find_by(token: params[:token])&.destroy
        head :no_content
      end

      private

      def forbidden_push
        render json: ErrorSerializer.serialize("Push not enabled for this account", status: 403), status: :forbidden
      end
    end
  end
end
