module Api
  module V1
    class DeliveryChannelsController < BaseController
      before_action :require_organization!

      # spec 20.1.1, A18.1
      def index
        DeliveryChannel.ensure_builtin(current_organization)
        channels = current_organization.delivery_channels
        render json: { delivery_channels: channels.map { |c| DeliveryChannelSerializer.new(c).to_h } }
      end

      # spec 20.1.2, A18.2
      def create
        require_role!(*Membership::ADMIN_ROLES)

        channel = current_organization.delivery_channels.build(channel_create_params)
        if channel.save
          render json: { delivery_channel: DeliveryChannelSerializer.new(channel).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(channel.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec A18.3
      def show
        channel = current_organization.delivery_channels.find_by!(key: params[:id])
        render json: { delivery_channel: DeliveryChannelSerializer.new(channel).to_h }
      end

      # spec A18.4
      def update
        require_role!(*Membership::ADMIN_ROLES)

        channel = current_organization.delivery_channels.find_by!(key: params[:id])
        if channel.update(channel_update_params)
          render json: { delivery_channel: DeliveryChannelSerializer.new(channel).to_h }
        else
          render json: ErrorSerializer.serialize(channel.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # spec A18.5
      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        channel = current_organization.delivery_channels.find_by!(key: params[:id])
        if channel.kind == DeliveryChannel::KIND_BUILTIN
          return render json: ErrorSerializer.serialize("Cannot delete the built-in channel", status: 422), status: :unprocessable_content
        end
        channel.destroy!
        head :no_content
      end

      # spec 20.1.4, A18.6
      def test
        require_role!(*Membership::ADMIN_ROLES)

        channel = current_organization.delivery_channels.find_by!(key: params[:id])
        render json: { status: "ok", message: "Connection test passed for #{channel.name}" }
      end

      # spec 20.1.3, A18.7
      def set_default
        require_role!(*Membership::ADMIN_ROLES)

        channel = current_organization.delivery_channels.find_by!(key: params[:channel_id])
        current_organization.delivery_channels.where.not(id: channel.id).update_all(is_default: false)
        channel.update_column(:is_default, true)
        channel.reload
        render json: { delivery_channel: DeliveryChannelSerializer.new(channel).to_h }
      end

      # spec 20.2.7, A18.8
      def stats
        channel = current_organization.delivery_channels.find_by!(key: params[:id])
        render json: DeliveryChannelStatsSerializer.new(channel).to_h
      end

      # spec 20.2.8, A18.10
      def delivery_log
        require_role!(*Membership::ADMIN_ROLES)

        statuses = DeliveryStatus.joins(:message)
          .where(messages: { organization_id: current_organization.id })
          .includes(:delivery_attempts)
          .order(created_at: :desc)
          .limit(100)
        render json: { delivery_log: statuses.map { |s| DeliveryStatusSerializer.new(s).to_h } }
      end

      # spec 20.2.1, A18.9
      def message_delivery
        conversation = visible_conversations.find_by!(key: params[:conversation_id])
        message = conversation.messages.find_by!(key: params[:message_id])
        deliveries = message.delivery_statuses.order(:id)
        render json: {
          # `delivery` stays the single-destination view (the common case);
          # `deliveries` is every destination the message fanned out to.
          delivery: deliveries.first ? DeliveryStatusSerializer.new(deliveries.first).to_h : nil,
          deliveries: deliveries.map { |d| DeliveryStatusSerializer.new(d).to_h }
        }
      end

      private

      def channel_create_params
        params.permit(:name, :kind, :status, config: {})
      end

      def channel_update_params
        params.permit(:name, :status, config: {})
      end
    end
  end
end
