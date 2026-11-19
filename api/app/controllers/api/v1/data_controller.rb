module Api
  module V1
    class DataController < BaseController
      before_action :require_organization!

      # spec 11.2.1, A15.4 — IMAP import. Network-bound + up to 1000 messages, so
      # it runs in a background job (never on the request thread); returns 202.
      def imap_import
        require_role!(*Membership::ADMIN_ROLES)

        ImapImportJob.perform_later(current_organization.id, imap_config)

        render json: {
          message: "IMAP import started for #{current_organization.default_domain&.name}",
          status: "processing"
        }, status: :accepted
      end

      # A single lightweight connect — fine to run inline.
      def imap_test
        require_role!(*Membership::ADMIN_ROLES)

        service = ImapImportService.new(current_organization, imap_config)
        render json: service.test_connection
      end

      # spec 11.3.3, A15.6 — Data export. Queues DataExportJob and returns 202
      # with the export. One in flight per org: asking again returns that one.
      def export
        require_role!(*Membership::ADMIN_ROLES)

        current_organization.data_exports.fail_stale!
        export = current_organization.data_exports.active.first
        unless export
          export = current_organization.data_exports.create!(requested_by: current_membership)
          DataExportJob.perform_later(export.id)
        end
        render json: { data_export: DataExportSerializer.new(export).to_h }, status: :accepted
      rescue ActiveRecord::RecordNotUnique
        # A concurrent request won the partial unique index; hand back its export.
        render json: { data_export: DataExportSerializer.new(current_organization.data_exports.active.first!).to_h },
               status: :accepted
      end

      # GET /orgs/:org_id/exports — latest first.
      def exports
        require_role!(*Membership::ADMIN_ROLES)

        rows = current_organization.data_exports.order(created_at: :desc, id: :desc).limit(20)
        render json: { data_exports: rows.map { |e| DataExportSerializer.new(e).to_h } }
      end

      # GET /orgs/:org_id/exports/:id/download — streams the zip from object
      # storage. Not a presigned redirect: prod's Garage endpoint is in-cluster
      # only, so a browser can't reach a signed URL (same reason as attachments).
      def export_download
        require_role!(*Membership::ADMIN_ROLES)

        export = current_organization.data_exports.find_by!(key: params[:id])
        if export.expired?
          return render json: ErrorSerializer.serialize("This export has expired. Start a new one.", status: 410), status: :gone
        end
        unless export.ready?
          return render json: ErrorSerializer.serialize("This export isn't ready yet.", status: 409), status: :conflict
        end

        storage = S3StorageService.new
        headers["Content-Type"] = "application/zip"
        headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename: export.filename)
        headers["Content-Length"] = export.byte_size.to_s if export.byte_size
        # no-store + Last-Modified keep Rack::ETag from buffering the whole body to hash it.
        headers["Cache-Control"] = "no-store"
        headers["Last-Modified"] = export.updated_at.httpdate
        self.response_body = Enumerator.new { |out| storage.stream(export.storage_key) { |chunk| out << chunk } }
      rescue S3StorageService::ConfigurationError, Seahorse::Client::NetworkingError, Aws::Errors::ServiceError => e
        Rails.logger.error("[DataController] export storage unavailable: #{e.class}: #{e.message}")
        render json: ErrorSerializer.serialize("File storage is unavailable. Try again shortly.", status: 503), status: :service_unavailable
      end

      # spec 11.3.5, A15.7 — GDPR contact data export/deletion
      def gdpr_export
        require_role!(*Membership::ADMIN_ROLES)

        email = params[:email]
        unless email.present?
          return render json: ErrorSerializer.serialize("Email address required", status: 422), status: :unprocessable_content
        end

        conversations = current_organization.conversations.where(from_address: email)
        messages = current_organization.messages.where(from_address: email)

        render json: {
          email: email,
          conversations_count: conversations.count,
          messages_count: messages.count,
          status: "export_ready"
        }
      end

      def gdpr_delete
        require_role!(*Membership::ADMIN_ROLES)

        email = params[:email]
        unless email.present?
          return render json: ErrorSerializer.serialize("Email address required", status: 422), status: :unprocessable_content
        end

        # Delete personal data for the contact
        current_organization.messages.where(from_address: email).update_all(
          from_address: "[redacted]",
          body_plain: "[content deleted per GDPR request]",
          body_html: nil
        )

        render json: { email: email, status: "deleted" }
      end

      private

      def imap_config
        {
          host: params[:host],
          port: params[:port],
          username: params[:username],
          password: params[:password],
          folder: params[:folder],
          ssl: params.fetch(:ssl, true)
        }
      end
    end
  end
end
