module Api
  module V1
    module Disk
      # Mail integration (spec F9), MX mail only: local channel mail never
      # reaches the API, so the web client moves those bytes itself.
      class MailController < BaseController
        # POST /messages/:message_id/attachments/:attachment_id/save-to-disk { parent_id, name, on_conflict }
        def save
          attachment = message.attachments.find_by!(key: params[:attachment_id].to_s)
          node = ::Disk::MailBridge.new(membership).save(attachment, parent_key: params.require(:parent_id),
                                                                     name: params[:name], on_conflict: params[:on_conflict])
          render json: { node: node_json(node.reload) }, status: :created
        end

        # POST /messages/:message_id/attachments/from-disk { node_id } — the
        # message must be a draft; the result is an attachment like an upload's,
        # to list in attachment_keys when sending.
        def attach
          raise ::Disk::Refused, "Files can only be attached to a draft" unless message.is_draft

          attachment = ::Disk::MailBridge.new(membership).attach(find_node!(params.require(:node_id)), message)
          render json: { attachment: AttachmentSerializer.new(attachment).to_h }, status: :created
        end

        private

        def message
          @message ||= current_organization.messages.where(conversation_id: visible_conversations.select(:id))
            .readable_by(membership)
            .find_by!(key: params[:message_id].to_s)
        end
      end
    end
  end
end
