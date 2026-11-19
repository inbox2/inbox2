module Api
  module V1
    # Cross-domain user management for admins. Spans every domain the acting user
    # owns or is an active admin of (see ManagesOrganizations) — never org-scoped,
    # and never exposes or mutates memberships in domains they don't manage (E3).
    class AdminUsersController < BaseController
      include ManagesOrganizations

      # GET /api/v1/admin/users
      def index
        org_ids = managed_organizations.map(&:id)
        return render(json: { users: [] }) if org_ids.empty?

        memberships = Membership.where(organization_id: org_ids).includes(:user, { organization: :domains }, mailboxes: :domain)
        users = memberships.group_by(&:user).map { |user, mships| serialize_user(user, mships) }
        render json: { users: users }
      end

      # GET /api/v1/admin/users/:user_id
      def show
        user = User.find_by!(key: params[:user_id])
        mships = managed_memberships_for(user)
        return user_not_found if mships.empty?

        render json: { user: serialize_user(user, mships) }
      end

      # POST /api/v1/admin/users/:user_id/assign — add the user to a domain.
      # Creates an `invited` membership (same as the invite flow). Params:
      # org_id (domain key), role?, local_part?.
      def assign
        org = managed_org(params[:org_id])
        return render_forbidden("Not allowed to assign to this domain") unless org

        role = Membership::ROLES.include?(params[:role]) ? params[:role] : Membership::ROLE_MEMBER
        return render_forbidden("Only an owner can grant the #{role} role") unless can_grant_role_in?(org, role)

        user = User.find_by!(key: params[:user_id])
        membership = nil
        # Locked so two assignments cannot both take the last seat, nor both
        # pass the already-a-member check.
        outcome = org.with_lock do
          membership = org.memberships.find_or_initialize_by(user: user)
          next :exists if membership.persisted?
          next :full if org.collaborator_limit_reached?

          membership.assign_attributes(role: role, status: Membership::STATUS_INVITED)
          membership.save!
          :created
        end
        if outcome == :exists
          return render json: ErrorSerializer.serialize("User already belongs to this domain", status: 422), status: :unprocessable_content
        end
        if outcome == :full
          return render json: ErrorSerializer.serialize("Upgrade required to add collaborators", status: 403), status: :forbidden
        end
        render json: { member: MembershipSerializer.new(membership, params: { avatar_org_key: org.key }).to_h }, status: :created
      end

      # DELETE /api/v1/admin/users/:user_id/assign?org_id=... — remove the user
      # from one domain (per-domain "disconnect"). No data/alias handling — for
      # offboarding with those choices, use destroy.
      def unassign
        org = managed_org(params[:org_id])
        return render_forbidden("Not allowed") unless org

        membership = org.memberships.find_by!(user: User.find_by!(key: params[:user_id]))
        return render_self_error if membership.user_id == current_user.id

        # A per-domain disconnect is intentionally gentle: we do NOT revoke the
        # user's sessions (they're global, so that would force a re-login on the
        # user's *other* domains too). Access to this domain drops on their next
        # request — accessible_organizations only resolves active memberships,
        # and this one is gone. Use disable/delete for a hard real-time kick.
        membership.destroy!
        head :no_content
      end

      # PATCH /api/v1/admin/users/:user_id/status — disable / re-enable. Params:
      # status (active|disabled), scope ("all" across managed domains | "membership"
      # for one domain, with org_id).
      def update_status
        new_status = params[:status]
        unless Membership::MANAGEABLE_STATUSES.include?(new_status)
          return render json: ErrorSerializer.serialize("Invalid status", status: 422), status: :unprocessable_content
        end

        user = User.find_by!(key: params[:user_id])
        memberships = status_scope_memberships(user)
        return if performed?
        return user_not_found if memberships.empty?
        return render_self_error if memberships.any? { |m| m.user_id == current_user.id }

        full = []
        Membership.transaction do
          # Re-enabling takes a seat in each org: lock them (id order), measure,
          # change, and undo everything if any org went over its plan's cap.
          orgs = memberships.map(&:organization).uniq.sort_by(&:id).each(&:lock!)
          before = orgs.to_h { |o| [o.id, o.collaborator_count] }
          Membership.where(id: memberships.map(&:id)).update_all(status: new_status, updated_at: Time.current)
          ::Disk::KeyGrant.freeze_holders!(memberships.map(&:id)) unless new_status == Membership::STATUS_ACTIVE
          full = orgs.select { |o| o.seats_exceeded_since?(before[o.id]) }
          raise ActiveRecord::Rollback if full.any?
        end
        if full.any?
          return render json: ErrorSerializer.serialize("Upgrade required to add collaborators on: #{full.map { |o| o.default_domain&.name }.compact.join(', ')}", status: 403), status: :forbidden
        end
        SessionRevoker.revoke_user!(user) if new_status == Membership::STATUS_DISABLED

        render json: { user: serialize_user(user, managed_memberships_for(user)) }
      end

      # DELETE /api/v1/admin/users/:user_id — offboard with data + alias handling.
      # Params: scope ("global" default | "domain" with org_id), data_handling
      # (archive|wipe), alias_handling (bounce|reroute), reroute_target_id.
      def destroy
        user = User.find_by!(key: params[:user_id])
        return render_self_error if user.id == current_user.id

        orgs = destroy_scope_orgs(user)
        return if performed?
        return user_not_found if orgs.empty?

        UserOffboarder.new(
          user: user,
          organizations: orgs,
          acting_user: current_user,
          data_handling: params[:data_handling],
          alias_handling: params[:alias_handling],
          reroute_target_key: params[:reroute_target_id]
        ).call

        SessionRevoker.revoke_user!(user)
        head :no_content
      rescue UserOffboarder::InvalidRerouteTarget
        render json: ErrorSerializer.serialize("reroute_target_id must be an active member of the domain", status: 422), status: :unprocessable_content
      end

      private

      def managed_org(key)
        managed_organizations.find { |o| o.key == key }
      end

      def managed_memberships_for(user)
        Membership.where(organization_id: managed_organizations.map(&:id), user: user)
          .includes(:organization, :user).to_a
      end

      def status_scope_memberships(user)
        if params[:scope] == "membership"
          org = managed_org(params[:org_id])
          unless org
            render_forbidden("Not allowed")
            return []
          end

          org.memberships.where(user: user).includes(:organization, :user).to_a
        else
          managed_memberships_for(user)
        end
      end

      def destroy_scope_orgs(user)
        if params[:scope] == "domain"
          org = managed_org(params[:org_id])
          unless org
            render_forbidden("Not allowed")
            return []
          end

          org.memberships.exists?(user: user) ? [org] : []
        else
          # Global (default; the only option for a single-domain user). One query
          # finds which managed domains the user belongs to.
          member_org_ids = Membership.where(organization_id: managed_organizations.map(&:id), user: user)
            .distinct.pluck(:organization_id)
          managed_organizations.select { |o| member_org_ids.include?(o.id) }
        end
      end

      def serialize_user(user, mships)
        AdminUserSerializer.new(user, params: { memberships: mships, avatar_org_key: mships.first&.organization&.key }).to_h
      end

      def render_forbidden(msg)
        render json: ErrorSerializer.serialize(msg, status: 403), status: :forbidden
      end

      def render_self_error
        render json: ErrorSerializer.serialize("Cannot modify your own access here", status: 422), status: :unprocessable_content
      end

      def user_not_found
        render json: ErrorSerializer.serialize("User not found in your domains", status: 404), status: :not_found
      end
    end
  end
end
