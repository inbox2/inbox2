module Api
  module V1
    # Cloud-synced per-channel open-tracking config (docs/Open-Tracking.md).
    # Authenticated (BaseController): a session (mx) OR an ink_ ApiKey both satisfy
    # authenticate_user! — which IS the "mx connected or api token entered" gate.
    # Local-channel opt-ins live here so they sync across the user's devices.
    class TrackingChannelsController < BaseController
      # GET /api/v1/tracking/channels
      def index
        settings = current_user.channel_tracking_settings.order(:email_address)
        render json: { channels: settings.map { |s| ChannelTrackingSettingSerializer.new(s).to_h } }
      end

      # PUT /api/v1/tracking/channels  { email, open_tracking_enabled, track_domain }
      def upsert
        email = params[:email].to_s.downcase.strip
        return render json: ErrorSerializer.serialize("email required", status: 422), status: :unprocessable_content if email.blank?

        setting = current_user.channel_tracking_settings.find_or_initialize_by(email_address: email)
        setting.open_tracking_enabled = ActiveModel::Type::Boolean.new.cast(params[:open_tracking_enabled]) unless params[:open_tracking_enabled].nil?
        setting.track_domain = params[:track_domain] if params.key?(:track_domain)

        if setting.save
          render json: { channel: ChannelTrackingSettingSerializer.new(setting).to_h }
        else
          render json: ErrorSerializer.serialize(setting.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end
    end
  end
end
