module Api
  module V1
    module Disk
      # Sharing a node with named members. On a sealed C:\ folder's root a
      # grant carries the scope key sealed to the person (build guide 6.7);
      # removing one goes through POST /scopes/:node_id/rotate.
      class GrantsController < BaseController
        # GET /nodes/:node_id/grants
        def index
          grants = node.grants.includes(:node, membership: :user, granted_by: :user).order(:created_at)
          render json: { grants: ::Disk::GrantSerializer.new(grants).to_h }
        end

        # PUT /nodes/:node_id/grants/:membership_id { role: view|edit } (+ sealed_key, epoch when sealed)
        def update
          target = current_organization.memberships.find_by!(key: params[:membership_id].to_s,
                                                             status: Membership::STATUS_ACTIVE)
          grant = ops.grant(node, target, params.require(:role), sealed_key: params[:sealed_key], epoch: params[:epoch])
          render json: { grant: ::Disk::GrantSerializer.new(grant).to_h }
        end

        # DELETE /nodes/:node_id/grants/:membership_id
        def destroy
          ops.ungrant(node, current_organization.memberships.find_by!(key: params[:membership_id].to_s))
          head :no_content
        end

        private

        def node = @node ||= find_node!(params[:node_id])
      end
    end
  end
end
