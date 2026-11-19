module Api
  module V1
    class AttachmentsController < BaseController
      before_action :require_organization!

      # spec 4.1.4, A7.2 — download an attachment's bytes.
      #
      # Streams through Rails rather than redirecting to a presigned S3 URL. The
      # redirect is cheaper, but no browser client can follow it: the app runs on
      # a different origin from the API (Pages) or on tauri://localhost, and a
      # cross-origin `fetch` of the S3 URL needs CORS configured on the bucket —
      # which Garage isn't, so every download failed at the redirect. Serving the
      # bytes keeps it on the origin the app's CORS + session already cover, and
      # works identically from web, desktop, iOS and Android.
      #
      # ponytail: proxying bytes costs API throughput. Attachments are capped by
      # the org's plan mail-size limit, so this is bounded; if it ever matters,
      # presigned_url is still there and the client can follow it once the bucket
      # has CORS.
      def show
        attachment = visible_attachments.find_by!(key: params[:id])

        if attachment.storage_key.blank?
          return render json: ErrorSerializer.serialize("Attachment content not available", status: 404), status: :not_found
        end

        data, stored_type = storage_service.download_with_type(attachment.storage_key)
        send_data data,
                  filename: attachment.filename.presence || "attachment",
                  type: attachment.content_type.presence || stored_type || "application/octet-stream",
                  disposition: "attachment"
      rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
        # The row can exist before its bytes land — a sealed attachment's
        # ciphertext is spooled to Garage by the MX after the row is written.
        render json: ErrorSerializer.serialize("Attachment content not available", status: 404), status: :not_found
      rescue S3StorageService::ConfigurationError, Seahorse::Client::NetworkingError, Aws::Errors::ServiceError => e
        # Storage down or unconfigured is not the caller's fault and not a
        # missing file — say so, the way the upload path already does, so the
        # client can tell "try again" from "this file is gone".
        Rails.logger.error("[AttachmentsController] storage unavailable: #{e.class}: #{e.message}")
        render json: ErrorSerializer.serialize("Storage service unavailable", status: 503), status: :service_unavailable
      end

      # spec 8.1.3, A7.3 — upload attachment to S3
      def create
        file = params[:file]
        unless file.present?
          return render json: ErrorSerializer.serialize("No file provided", status: 422), status: :unprocessable_content
        end

        # Enforce plan-based size limit (the org's effective plan)
        size_limit = current_organization.effective_mail_size_limit
        if file.size > size_limit
          return render json: ErrorSerializer.serialize(
            "File exceeds the #{size_limit / 1_048_576}MB limit for your plan", status: 422
          ), status: :unprocessable_content
        end

        # Message association required — resolved BEFORE the upload, so a bad or
        # foreign message_id costs a 404, not an orphaned object in the bucket.
        unless params[:message_id].present?
          return render json: ErrorSerializer.serialize("message_id is required", status: 422), status: :unprocessable_content
        end
        message = Message.where(conversation: visible_conversations).readable_by(current_membership).find_by!(key: params[:message_id])

        # Read once, reuse the bytes for both upload and text indexing
        data = file.read

        # Upload to S3
        storage_key = storage_service.upload(
          data,
          filename: file.original_filename,
          content_type: file.content_type,
          organization_key: current_organization.key
        )

        attachment = current_organization.attachments.create!(
          message: message,
          filename: file.original_filename,
          content_type: file.content_type,
          size_bytes: file.size,
          storage_key: storage_key
        )

        # Extract text for search indexing
        if attachment.searchable?
          text = begin
            data.dup.force_encoding("UTF-8")
          rescue StandardError
            nil
          end
          attachment.update!(content_text: text)
        end

        render json: { attachment: AttachmentSerializer.new(attachment).to_h }, status: :created
      rescue Aws::Errors::ServiceError => e
        Rails.logger.error("[AttachmentsController] S3 upload failed: #{e.message}")
        render json: ErrorSerializer.serialize("Storage service unavailable", status: 503), status: :service_unavailable
      end

      # Remove a file from the caller's own draft. Sent mail keeps its files, and
      # a colleague's draft is a 404 like any other row out of reach.
      def destroy
        attachment = own_draft_attachments.find_by!(key: params[:id])
        message_id = attachment.message_id
        storage_key = attachment.storage_key
        attachment.destroy!
        Message.refresh_search_vectors([message_id])
        remove_stored_object(storage_key)
        head :no_content
      end

      private

      def own_draft_attachments
        current_organization.attachments.joins(:message).where(
          messages: { conversation_id: visible_conversations.select(:id), is_draft: true,
                      owner_membership_id: current_membership&.id }
        )
      end

      # The row is already gone, so a storage hiccup only strands an unreachable object.
      def remove_stored_object(storage_key)
        storage_service.delete(storage_key) if storage_key.present?
      rescue S3StorageService::ConfigurationError, Seahorse::Client::NetworkingError, Aws::Errors::ServiceError => e
        Rails.logger.error("[AttachmentsController] couldn't delete #{storage_key}: #{e.class}: #{e.message}")
      end

      # Attachments on threads this member may see — the same slice as
      # conversations#show renders, so a key lifted from elsewhere (another
      # domain's thread, a colleague's private import) is a 404 here too.
      def visible_attachments
        current_organization.attachments.joins(:message)
          .where(messages: { conversation_id: visible_conversations.select(:id) })
          .merge(Message.readable_by(current_membership))
      end

      def storage_service
        @storage_service ||= S3StorageService.new
      end
    end
  end
end
