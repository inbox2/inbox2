module Api
  module V1
    module Disk
      # Share roles. Anyone who can see the share lists them; managers change them.
      class ShareMembersController < BaseController
        # GET /shares/:share_id/members
        def index
          rows = share.share_memberships.includes(membership: :user).order(:created_at)
          render json: { members: ::Disk::ShareMemberSerializer.new(rows).to_h }
        end

        # PUT /shares/:share_id/members/:membership_id { role } and, on a sealed
        # share, the scope key sealed to them: { role, sealed_key, epoch } (6.7).
        def update
          ops.require_role!(share.root_node, ::Disk::ROLE_MANAGE)
          target = active_member!
          row = share.share_memberships.find_or_initialize_by(membership: target)
          action = row.new_record? ? ::Disk::Event::ACTION_MEMBER_ADDED : ::Disk::Event::ACTION_MEMBER_CHANGED
          row.organization_id = current_organization.id
          row.role = params.require(:role).to_s
          if share.root_node.sealed?
            ::Disk::Sealing.add_holder!(share.root_node, actor: membership, target: target, sealed_key: params[:sealed_key],
                                                         epoch: params[:epoch]) { row.save! }
          else
            row.save!
          end
          ::Disk::Event.record!(action, actor: membership, share: share, member: target.key, role: row.role)
          if action == ::Disk::Event::ACTION_MEMBER_ADDED
            ::Disk::ShareNotifier.added_to_share(actor: membership, target: target, share: share, role: row.role)
          end
          render json: { member: ::Disk::ShareMemberSerializer.new(row).to_h }
        end

        # DELETE /shares/:share_id/members/:membership_id
        def destroy
          ops.require_role!(share.root_node, ::Disk::ROLE_MANAGE)
          raise ops.use_rotate if share.root_node.sealed?

          target = active_member!
          share.share_memberships.find_by!(membership: target).destroy!
          ::Disk::Event.record!(::Disk::Event::ACTION_MEMBER_REMOVED, actor: membership, share: share, member: target.key)
          head :no_content
        end

        private

        def share
          @share ||= ::Disk::Share.find_by_ref!(::Disk::Access.visible_shares(membership), params[:share_id])
        end

        def active_member!
          current_organization.memberships.find_by!(key: params[:membership_id].to_s, status: Membership::STATUS_ACTIVE)
        end
      end
    end
  end
end
