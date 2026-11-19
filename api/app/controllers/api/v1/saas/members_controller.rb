module Api
  module V1
    module Saas
      # Org user management for a platform operator: list/add/remove members of any
      # domain (no membership required). Reuses the offboarding pipeline for removal.
      class MembersController < BaseController
        before_action :set_organization

        # GET /api/v1/saas/organizations/:organization_id/members
        def index
          members = @organization.memberships.includes(:user, mailboxes: :domain)
          render json: { members: members.map { |m| ::MembershipSerializer.new(m, params: { avatar_org_key: @organization.key }).to_h } }
        end

        # POST /api/v1/saas/organizations/:organization_id/members
        # Creates an invited membership. Addresses are added separately as
        # mailboxes. Params: email, role?.
        def create
          user = find_or_create_user(params[:email])
          return render_error("email is required", status: :unprocessable_content) unless user

          membership = @organization.memberships.find_or_initialize_by(user: user)
          if membership.persisted?
            return render_error("User already belongs to this domain", status: :unprocessable_content)
          end

          role = Membership::ROLES.include?(params[:role]) ? params[:role] : Membership::ROLE_MEMBER
          membership.assign_attributes(role: role, status: Membership::STATUS_INVITED)

          if membership.save
            audit!(::SaasAuditLog::ACTION_ORG_MEMBER_ADD, target: @organization, metadata: { user: user.key, role: role })
            render json: { member: ::MembershipSerializer.new(membership, params: { avatar_org_key: @organization.key }).to_h }, status: :created
          else
            render_error(membership.errors.full_messages, status: :unprocessable_content)
          end
        end

        # DELETE /api/v1/saas/organizations/:organization_id/members/:id
        # Offboards the member from this one domain (data_handling/alias_handling
        # honored), then hard-revokes their sessions.
        def destroy
          membership = @organization.memberships.find_by!(key: params[:id])
          user = membership.user

          UserOffboarder.new(
            user: user, organizations: [@organization], acting_user: nil,
            data_handling: params[:data_handling], alias_handling: params[:alias_handling],
            reroute_target_key: params[:reroute_target_id]
          ).call
          SessionRevoker.revoke_user!(user)

          audit!(::SaasAuditLog::ACTION_ORG_MEMBER_REMOVE, target: @organization, metadata: { user: user.key })
          head :no_content
        rescue UserOffboarder::InvalidRerouteTarget
          render_error("reroute_target_id must be an active member of the domain", status: :unprocessable_content)
        end

        private

        def set_organization
          @organization = Organization.find_by!(key: params[:organization_id])
        end

        def find_or_create_user(email)
          email = email.to_s.strip
          return nil if email.blank?

          User.find_by(billing_email: email) ||
            User.create!(username: "invited_#{SecureRandom.hex(6)}", password: SecureRandom.hex(16), billing_email: email)
        end
      end
    end
  end
end
