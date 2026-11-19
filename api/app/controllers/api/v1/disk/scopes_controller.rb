module Api
  module V1
    module Disk
      # Sealed scopes (build guide 6.7): what a member needs to open one, and
      # the two ways its key holders change hands.
      class ScopesController < BaseController
        # GET /scopes/:node_id
        def show = render_scope(scope_root!)

        # POST /scopes/:node_id/rotate { remove: [membership ids], epoch, previous_key_wrapped,
        #                                grants: [{ membership_id, sealed_key }] }
        def rotate
          root = scope_root!
          ops.require_role!(root, ::Disk::ROLE_MANAGE)
          p = params.permit(:epoch, :previous_key_wrapped, remove: [], grants: %i[membership_id sealed_key])
          ::Disk::Sealing.rotate!(root, actor: membership, remove: p[:remove] || [], epoch: p[:epoch],
                                        previous_key_wrapped: p[:previous_key_wrapped], grants: p[:grants] || [])
          render_scope(root.reload)
        end

        # POST /scopes/:node_id/transfer { membership_id, sealed_key, epoch }
        def transfer
          target = current_organization.memberships.find_by!(key: params.require(:membership_id).to_s,
                                                             status: Membership::STATUS_ACTIVE)
          root = ops.transfer(scope_root!, target, sealed_key: params.require(:sealed_key), epoch: params.require(:epoch))
          render_scope(root.reload)
        end

        private

        def scope_root!
          node = find_node!(params[:node_id])
          raise ::Disk::Refused, "This is not a sealed folder's top" unless node.scope_root?

          node
        end

        def render_scope(root)
          manager = ::Disk::Access.allows?(membership, root, ::Disk::ROLE_MANAGE)
          render json: { scope: ::Disk::ScopeSerializer.new(root, params: { membership: membership, manager: manager }).to_h }
        end
      end
    end
  end
end
