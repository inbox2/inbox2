module Api
  module V1
    # A person imports their own mail export (an .mbox, as Google Takeout writes
    # it) into one of their own mailboxes, from Settings › Account. The file goes
    # up through the Disk uploader first (resumable, straight to storage); this
    # reads it from there. The history lands private to them, the same as an
    # admin-run import (docs/plans/mail-import.md, "Takeout").
    class MyMailImportsController < BaseController
      before_action :require_organization!

      # GET /orgs/:org_id/my-mail-imports — my mailboxes in this org and my imports.
      def index
        render json: { mailboxes: MailboxSerializer.new(my_mailboxes).to_h, imports: MailImportSerializer.new(my_imports).to_h }
      end

      # POST /orgs/:org_id/my-mail-imports { mailbox_id, node_id } — a new file
      # for a mailbox starts its import over; mail already there counts as duplicate.
      def create
        mailbox = my_mailboxes.find_by!(key: params.require(:mailbox_id))
        node = ::Disk::Access.scope_for(membership).find_by!(key: ::Disk::Node.key_for(params.require(:node_id)))
        return refuse("Choose an .mbox file.", 422) if node.folder? || node.current_version.nil?
        return refuse("You can't import a sealed file.", 422) if node.current_version.sealed?

        import = MailImport.find_or_initialize_by(organization: current_organization, provider: MailImport::TAKEOUT,
                                                  source_email: mailbox.email_address.downcase)
        # A queued or running job still owns the row (a stale one included): resetting
        # it under that job would mix two runs. Stop it first; the job sees the cancel.
        if import.persisted? && (import.queued? || import.running?)
          return refuse("An import into #{mailbox.email_address} is running. Stop it first.", 409)
        end
        # The address belonged to someone else before: their thread mappings would
        # put this mail into their private conversations.
        import.threads.delete_all if import.persisted? && import.owner_membership_id != membership.id

        import.assign_attributes(membership: membership, owner: membership, domain: mailbox.domain, source_node: node,
                                 cursor: nil, counts: {}, report: {}, started_at: nil)
        queue!(import)
        render json: { import: MailImportSerializer.new(import).to_h }, status: :accepted
      end

      # POST /orgs/:org_id/my-mail-imports/:id/resume — from where it stopped.
      def resume
        import = find_import
        # Deleted, or no longer visible to me (a grant revoked since): pick a file again.
        unless import.source_node_id && ::Disk::Access.scope_for(membership).exists?(id: import.source_node_id)
          return refuse("The .mbox file is no longer on Disk. Upload it again.", 422)
        end
        return refuse("This import is already running.", 409) unless import.resumable?

        queue!(import)
        render json: { import: MailImportSerializer.new(import).to_h }
      end

      # DELETE /orgs/:org_id/my-mail-imports/:id — cancels; what arrived stays.
      def destroy
        import = find_import
        import.update!(state: MailImport::STATE_CANCELLED) unless import.done?
        render json: { import: MailImportSerializer.new(import).to_h }
      end

      private

      def membership = current_active_membership!
      def my_mailboxes = membership.mailboxes.includes(:domain, :membership)

      def my_imports
        MailImport.where(organization: current_organization, owner: membership, provider: MailImport::TAKEOUT)
          .includes(:domain, :connection, owner: :user, source_node: :current_version).order(:source_email)
      end

      def find_import = my_imports.find_by!(key: params[:id])

      def queue!(import)
        import.assign_attributes(state: MailImport::STATE_QUEUED, pause_reason: nil, error: nil, finished_at: nil)
        import.save!
        MailImportJob.perform_later(import.id)
      end

      def refuse(message, status)
        render json: ErrorSerializer.serialize(message, status: status), status: status
      end
    end
  end
end
