module Api
  module V1
    # Mail import (docs/plans/mail-import.md): an owner or admin moves a
    # domain's mailboxes from Google Workspace or Microsoft 365 into each
    # member's private history. Uses the Disk importer's org-reach connection
    # for the source (connected under Disk › Import) and its credentials.
    class MailImportsController < BaseController
      before_action :require_organization!
      before_action -> { require_role!(*Membership::ADMIN_ROLES) }

      # GET /orgs/:org_id/mail-imports — every import, and which sources are
      # ready (configured, allowed, connected for the whole organization).
      def index
        imports = MailImport.where(organization: current_organization)
          .includes(:domain, :connection, owner: :user).order(:source_email)
        sources = MailImport::PROVIDERS.map do |p|
          { provider: p, offered: ::Disk::ImportSource.offered?(p, current_organization), connected: connection(p).present? }
        end
        render json: { imports: MailImportSerializer.new(imports).to_h, sources: sources }
      end

      # POST /orgs/:org_id/mail-imports { provider, domain_id } — one import per
      # source user whose address has a mailbox on the domain, each queued.
      # Users without one are listed back (create the mailbox, then ask again);
      # asking again also re-runs finished imports (the catch-up after the MX flip).
      def create
        provider = params.require(:provider).to_s
        domain = current_organization.domains.find_by!(key: params.require(:domain_id))
        unless MailImport::PROVIDERS.include?(provider) && ::Disk::ImportSource.offered?(provider, current_organization)
          return refuse("#{provider} import is not available for this organization", 422)
        end
        conn = connection(provider) or
          return refuse("Connect #{OauthProvider.label(provider)} for the whole organization first (Disk › Import)", 422)

        users = MailImporter.for(MailImport.new(organization: current_organization, provider: provider, connection: conn)).directory
        mailboxes = domain.mailboxes.includes(:membership).index_by { |m| m.local_part.downcase }
        unmatched = []
        imports = users.filter_map do |email, _name|
          local, host = email.to_s.downcase.split("@", 2)
          next unless host == domain.name.downcase

          mailbox = mailboxes[local] or (unmatched << email.downcase and next)
          start(provider, domain, conn, mailbox.membership, email.downcase)
        end
        render json: { imports: MailImportSerializer.new(imports).to_h, unmatched: unmatched }, status: :accepted
      rescue ::Disk::Importer::Stop, ::Disk::Importer::ItemFailed, ::Disk::Refused => e
        refuse(e.message, 422)
      rescue ::Disk::Importer::Throttled => e
        refuse("#{OauthProvider.label(provider)} asked us to wait #{e.wait} seconds; try again then", 503)
      end

      # POST /orgs/:org_id/mail-imports/:id/resume — a paused or cancelled
      # import, or a finished one again (reads only what arrived since).
      def resume
        import = find_import
        if import.provider == MailImport::TAKEOUT && import.source_node_id.nil?
          return refuse("A Takeout import resumes only from its file (rake mail_import:takeout)", 422)
        end
        return refuse("This import is running", 409) unless import.resumable?

        queue!(import)
        render json: { import: MailImportSerializer.new(import).to_h }
      end

      # DELETE /orgs/:org_id/mail-imports/:id — cancels; what arrived stays.
      def destroy
        import = find_import
        import.update!(state: MailImport::STATE_CANCELLED) unless import.done?
        render json: { import: MailImportSerializer.new(import).to_h }
      end

      private

      def connection(provider)
        ::Disk::ImportConnection.where(organization: current_organization, provider: provider,
                                     reach: ::Disk::ImportConnection::REACH_ORG).order(updated_at: :desc).first
      end

      def find_import = MailImport.where(organization: current_organization).find_by!(key: params[:id])

      def start(provider, domain, conn, owner, email)
        import = MailImport.find_or_initialize_by(organization: current_organization, provider: provider, source_email: email)
        import.assign_attributes(domain: domain, connection: conn, owner: owner, membership: current_membership)
        import.state ||= MailImport::STATE_QUEUED
        import.save!
        queue!(import) if import.previously_new_record? || import.resumable?
        import
      end

      def queue!(import)
        import.update!(state: MailImport::STATE_QUEUED, pause_reason: nil, error: nil, finished_at: nil)
        MailImportJob.perform_later(import.id)
      end

      def refuse(message, status)
        render json: ErrorSerializer.serialize(message, status: status), status: status
      end
    end
  end
end
