module Api
  module V1
    module Saas
      class UsersController < BaseController
        before_action :set_user, except: :index

        # GET /api/v1/saas/users?q=&page=&per_page=
        def index
          scope = User.all
          if (q = params[:q]).present?
            like = "%#{q.strip.downcase}%"
            scope = scope.where("LOWER(username) LIKE :q OR LOWER(display_name) LIKE :q OR LOWER(billing_email) LIKE :q", q: like)
          end
          scope = scope.includes(:owned_organizations, memberships: [{ mailboxes: :domain }, { organization: :domains }]).order(created_at: :desc)
          records, meta = paginate(scope, default_per_page: 25, max_per_page: 100)
          render json: { users: records.map { |u| serialize(u) }, meta: meta }
        end

        # GET /api/v1/saas/users/:id
        def show
          render json: { user: serialize(@user) }
        end

        # POST /api/v1/saas/users/:id/reset_password — issue a reset token
        # and dispatch the reset email (via Messy).
        def reset_password
          unless PasswordResetService.call(@user)
            return render_error("User has no billing email to send a reset to", status: :unprocessable_content)
          end

          audit!(::SaasAuditLog::ACTION_USER_RESET_PASSWORD, target: @user)
          head :accepted
        end

        # POST /api/v1/saas/users/:id/disable — disable every membership and
        # hard-revoke sessions (real-time kick).
        def disable
          Membership.transaction do
            Membership.where(user: @user).update_all(status: Membership::STATUS_DISABLED, updated_at: Time.current)
            ::Disk::KeyGrant.freeze_holders!(Membership.where(user: @user).select(:id))
          end
          SessionRevoker.revoke_user!(@user)
          audit!(::SaasAuditLog::ACTION_USER_DISABLE, target: @user)
          render json: { user: serialize(@user.reload) }
        end

        # POST /api/v1/saas/users/:id/enable — re-activate disabled memberships.
        def enable
          Membership.where(user: @user, status: Membership::STATUS_DISABLED)
            .update_all(status: Membership::STATUS_ACTIVE, updated_at: Time.current)
          audit!(::SaasAuditLog::ACTION_USER_ENABLE, target: @user)
          render json: { user: serialize(@user.reload) }
        end

        # DELETE /api/v1/saas/users/:id/offboard — global offboard across
        # every domain the user belongs to.
        def offboard
          UserOffboarder.new(
            user: @user, organizations: offboard_orgs, acting_user: nil,
            data_handling: params[:data_handling], alias_handling: params[:alias_handling],
            reroute_target_key: params[:reroute_target_id]
          ).call
          SessionRevoker.revoke_user!(@user)
          audit!(::SaasAuditLog::ACTION_USER_OFFBOARD, target: @user)
          head :no_content
        rescue UserOffboarder::InvalidRerouteTarget
          render_error("reroute_target_id must be an active member of the domain", status: :unprocessable_content)
        end

        private

        def set_user
          @user = User.find_by!(key: params[:id])
        end

        def offboard_orgs
          org_ids = Membership.where(user: @user).distinct.pluck(:organization_id)
          Organization.where(id: org_ids).to_a
        end

        def serialize(user)
          ::Saas::UserSerializer.new(user).to_h
        end
      end
    end
  end
end
