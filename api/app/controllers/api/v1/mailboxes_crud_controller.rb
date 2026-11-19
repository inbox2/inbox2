module Api
  module V1
    # CRUD for per-domain mailboxes (a member's address on a domain). Separate from
    # MailboxesController (which serves Command-Center graph/stats). Creation is
    # gated by the org's mailbox cap.
    class MailboxesCrudController < BaseController
      before_action :require_organization!
      before_action -> { require_role!(*Membership::ADMIN_ROLES) }, only: %i[create destroy]

      def index
        mailboxes = current_organization.mailboxes.includes(:domain, :membership)
        # A domain-scoped member lists their own teams' addresses only (E3).
        me = current_active_membership!
        mailboxes = mailboxes.where(domain_id: me.home_domain_ids) unless me.all_domains_access?
        render json: { mailboxes: mailboxes.map { |m| MailboxSerializer.new(m).to_h } }
      end

      def create
        if current_organization.mailbox_limit_reached?
          return render json: ErrorSerializer.serialize("Mailbox limit reached for this organization", status: 403), status: :forbidden
        end

        membership = current_organization.memberships.find_by!(key: params[:membership_id])
        domain = current_organization.domains.find_by!(key: params[:domain_id])
        mailbox = Mailbox.new(membership: membership, domain: domain, local_part: params[:local_part])

        if mailbox.save
          render json: { mailbox: MailboxSerializer.new(mailbox).to_h }, status: :created
        else
          render json: ErrorSerializer.serialize(mailbox.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      def destroy
        mailbox = current_organization.mailboxes.find_by!(key: params[:id])
        mailbox.destroy!
        head :no_content
      end
    end
  end
end
