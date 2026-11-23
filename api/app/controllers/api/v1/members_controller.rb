module Api
  module V1
    class MembersController < BaseController
      include ManagesOrganizations

      before_action :require_organization!, except: %i[accept_invite invite_mx]
      skip_before_action :authenticate_user!, only: :accept_invite

      # spec 5.1.3, A4.1
      def index
        # A domain-scoped caller sees only teammates on their own domains, and only
        # those domains' addresses — not the org's other teams (Membership#teammates).
        me = current_active_membership!
        home = me.all_domains_access? ? nil : me.home_domain_ids
        members = me.teammates.includes(:user)
        render json: { members: members.map { |m| MembershipSerializer.new(m, params: { avatar_org_key: current_organization.key, domain_ids: home, hide_private: !me.admin? }).to_h } }
      end

      # POST /api/v1/members/invite-mx — invite one person to a private mailbox on
      # several of the inviter's domains at once (local_part@each-domain). Creates
      # an `invited` membership per domain; accept-invite activates them all.
      def invite_mx
        email = params[:email].to_s.strip
        role = Membership::ROLES.include?(params[:role]) ? params[:role] : Membership::ROLE_MEMBER
        domain_keys = Array(params[:domain_ids]).reject(&:blank?).uniq

        if email.blank? || domain_keys.empty?
          return render json: ErrorSerializer.serialize("email and at least one domain are required", status: 422), status: :unprocessable_content
        end

        # `domain_ids` are Domain keys (the address lands on that exact domain), not
        # org keys — same interpretation as updateMember's domain access. Resolve
        # them only within domains the current user manages (tenant isolation).
        # Sorted back into the order the caller listed them: an unordered `where`
        # returns rows in whatever order Postgres likes, and the invite email
        # names the first domain in its subject — so the same request could be
        # titled after a different domain run to run.
        domains = Domain.where(key: domain_keys, organization: managed_organizations)
          .includes(:organization).to_a
          .sort_by { |d| domain_keys.index(d.key) }
        unless domains.length == domain_keys.length
          return render json: ErrorSerializer.serialize("Not allowed to invite to one of these domains", status: 403), status: :forbidden
        end

        orgs = domains.map(&:organization).uniq
        # Grant ceiling: granting admin/owner requires owner in every target org.
        unless orgs.all? { |o| can_grant_role_in?(o, role) }
          return render json: ErrorSerializer.serialize("Only an owner can grant the #{role} role", status: 403), status: :forbidden
        end

        user = find_or_create_invited_user(email)

        local_part = mailbox_local_part(params[:local_part], email)

        touched = []       # every membership that got a new address (returned)
        new_invites = []   # only freshly-created invited memberships (get the email)
        full = []
        begin
          ActiveRecord::Base.transaction do
            # Collaborator cap per target org (every seat but the primary owner's,
            # owners included) — skip orgs the user already belongs to, block any
            # remaining org that's at its plan's limit. The orgs are locked (id
            # order) so two invites cannot both take the last seat.
            orgs.sort_by(&:id).each(&:lock!)
            full = orgs.reject { |o| o.memberships.exists?(user: user) }.select(&:collaborator_limit_reached?)
            raise ActiveRecord::Rollback if full.any?

            # One membership per org (a member has a single membership per org), a
            # mailbox per specific domain — so multi-domain orgs place each address
            # on the chosen domain, not the org's default.
            domains.group_by(&:organization).each do |org, org_domains|
              membership = org.memberships.find_by(user: user)
              if membership.nil?
                membership = org.memberships.create!(user: user, role: role, status: Membership::STATUS_INVITED)
                membership.mint_invite_token!
                new_invites << membership
              end
              org_domains.each { |d| membership.mailboxes.create!(domain: d, local_part: local_part) }
              touched << membership
            end
          end
        rescue ActiveRecord::RecordInvalid => e
          return render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
        end
        if full.any?
          return render json: ErrorSerializer.serialize("Upgrade required to add collaborators on: #{full.map { |o| o.default_domain&.name }.compact.join(', ')}", status: 403), status: :forbidden
        end

        InviteMailerService.send_invite(email: email, inviter: current_user, invites: new_invites) if new_invites.any?

        render json: { invites: touched.uniq.map { |m| MembershipSerializer.new(m).to_h } }, status: :created
      end

      # spec 5.1.1, A4.3
      def accept_invite
        # `invite_id` is the single-use token from the invite email (never the
        # membership key, which every teammate can read off the Team tab).
        membership = Membership.find_by_invite_token(params[:invite_id]) or raise ActiveRecord::RecordNotFound
        user = membership.user

        # Even with a secret token, it must never reset the credentials of an
        # account that already belongs to someone (a forwarded invite mail).
        # Only a fresh invite stub may have its username/password set here; an
        # existing user must be signed in as themselves to accept (we then just
        # activate the pending memberships).
        if user_already_claimed?(user)
          unless current_user == user
            return render json: ErrorSerializer.serialize("Sign in to this account to accept the invitation", status: 401), status: :unauthorized
          end

          activate_pending_invites(user)
          return render json: { user: UserSerializer.new(user).to_h, admin: admin_anywhere?(user) }
        end

        ActiveRecord::Base.transaction do
          user.update!(username: accept_invite_params[:username], password: accept_invite_params[:password])
          # Activate EVERY pending invite for this person, so they land on all the
          # domains they were invited to (each becomes an inbox2 tab on login).
          activate_pending_invites(user)
        end

        session = create_session_for(user)
        render json: { user: UserSerializer.new(user).to_h, token: session.raw_token, admin: admin_anywhere?(user) }
      rescue ActiveRecord::RecordInvalid => e
        render json: ErrorSerializer.serialize(e.record.errors.full_messages, status: 422), status: :unprocessable_content
      end

      # spec 5.1.5, 5.1.4, A4.4
      def update
        require_role!(*Membership::ADMIN_ROLES)

        membership = current_organization.memberships.find_by!(key: params[:id])

        if membership.user == current_user && params[:role].present?
          return render json: ErrorSerializer.serialize("Cannot change your own role", status: 422), status: :unprocessable_content
        end

        # An admin can't manage someone ranked at or above them (only an owner can
        # touch an owner/admin). Owners can manage anyone.
        unless current_membership.owner? || membership.rank < current_membership.rank
          return render json: ErrorSerializer.serialize("Only an owner can modify an admin or owner", status: 403), status: :forbidden
        end

        # Grant ceiling: changing someone *to* admin/owner is owner-only.
        if params[:role].present? && !current_membership.can_grant_role?(params[:role])
          return render json: ErrorSerializer.serialize("Only an owner can grant the #{params[:role]} role", status: 403), status: :forbidden
        end

        saved = nil
        full = false
        current_organization.with_lock do
          # A re-enable or a role change can take a seat (plan cap): measured
          # under the org lock and undone when it went over.
          before = current_organization.collaborator_count
          membership.assign_attributes(member_update_params)
          apply_domain_access!(membership) if params.key?(:all_domains) || params.key?(:domain_ids)
          saved = membership.save
          full = saved && current_organization.seats_exceeded_since?(before)
          raise ActiveRecord::Rollback if full
        end

        if full
          render json: ErrorSerializer.serialize("Upgrade required to add collaborators", status: 403), status: :forbidden
        elsif saved
          render json: { member: MembershipSerializer.new(membership).to_h }
        else
          render json: ErrorSerializer.serialize(membership.errors.full_messages, status: 422), status: :unprocessable_content
        end
      end

      # POST /orgs/:org_id/members/:id/resend-invite — email the invite again to a
      # member who hasn't accepted yet. Same mail as the original invite.
      def resend_invite
        require_role!(*Membership::ADMIN_ROLES)

        membership = current_organization.memberships.invited.find_by!(key: params[:id])
        # A fresh token every time: the old mail's link stops working, so a
        # resend also revokes an invite that went to the wrong place.
        membership.mint_invite_token!
        InviteMailerService.send_invite(email: membership.user.billing_email, inviter: current_user, invites: [membership])
        render json: { member: MembershipSerializer.new(membership).to_h }
      end

      # spec 5.1.4, A4.5
      def destroy
        require_role!(*Membership::ADMIN_ROLES)

        membership = current_organization.memberships.find_by!(key: params[:id])

        if membership.user == current_user
          return render json: ErrorSerializer.serialize("Cannot remove yourself", status: 422), status: :unprocessable_content
        end

        membership.destroy!
        head :no_content
      end

      private

      # A user is "claimed" once it's a real account rather than a fresh invite
      # stub. A stub (created by find_or_create_invited_user) has never logged in
      # and has only `invited` memberships; any real account has a session (signup
      # creates one) or an active membership. Claimed accounts must never have
      # their credentials overwritten through the unauthenticated accept path —
      # the invite key is visible to the inviter.
      def user_already_claimed?(user)
        user.sessions.exists? ||
          user.memberships.active.exists?
      end

      def activate_pending_invites(user)
        user.memberships.invited
          .update_all(status: Membership::STATUS_ACTIVE, invite_token_digest: nil, updated_at: Time.current)
      end

      # The invitee's mailbox name on each target domain: the form's value if
      # given, else derived from their external address ("jo.doe@x.com" → "jo.doe"),
      # squeezed into LOCAL_PART_FORMAT. Mailbox validations still apply (format,
      # per-domain uniqueness).
      def mailbox_local_part(param, email)
        explicit = param.to_s.strip.downcase
        return explicit if explicit.present?

        email.split("@").first.to_s.downcase.gsub(/[^a-z0-9._-]/, "")
      end

      # Whether the user is an admin/owner on any active membership — drives the
      # post-accept landing (console for managers, inbox for members).
      def admin_anywhere?(user)
        user.memberships.active.admins.exists?
      end

      def find_or_create_invited_user(email)
        User.find_by(billing_email: email) ||
          User.create!(
            username: "invited_#{SecureRandom.hex(6)}",
            password: SecureRandom.hex(16),
            billing_email: email
          )
      end

      def accept_invite_params
        params.permit(:invite_id, :username, :password)
      end

      # :role is checked in #update first: admins only, never your own, and only a
      # role current_membership.can_grant_role? allows.
      def member_update_params
        params.permit(:role, :status, send_as_addresses: []).tap do |p| # nosemgrep: ruby.lang.security.model-attr-accessible
          # Only allow manageable status transitions (not back to "invited")
          p.delete(:status) if p[:status].present? && !Membership::MANAGEABLE_STATUSES.include?(p[:status])
        end
      end

      # Set a member's domain access. all_domains:true (whole pool) clears grants;
      # otherwise the member is scoped to the given domain keys — zero keys makes
      # them a "limited member" who sees only shared/rule-matched threads. Domains
      # are resolved within the current org (tenant isolation).
      def apply_domain_access!(membership)
        if params[:all_domains].to_s == "true"
          membership.all_domains = true
          membership.domains = []
        else
          membership.all_domains = false
          keys = Array(params[:domain_ids]).reject(&:blank?)
          membership.domains = current_organization.domains.where(key: keys)
        end
      end

      def free_plan?
        current_organization.on_free_plan?
      end
    end
  end
end
