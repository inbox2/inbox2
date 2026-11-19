module Api
  module V1
    module Disk
      # Which shares and folders an agent may reach over MCP (build guide 9c).
      # Owners and admins grant; nobody can give an agent more than they have.
      class AgentGrantsController < BaseController
        before_action :require_admin!

        # GET /agents/:agent_id/grants
        def index
          grants = agent.disk_grants.includes(:agent, granted_by: :user, node: :share).order(:created_at)
          paths = visible_paths(grants.map(&:node))
          render json: { grants: ::Disk::AgentGrantSerializer.new(grants, params: { paths: paths }).to_h }
        end

        # PUT /agents/:agent_id/grants/:node_id { role: view|edit }
        def update
          node = find_node!(params[:node_id])
          role = params.require(:role).to_s
          raise ::Disk::Refused, "role must be view or edit" unless ::Disk::AgentGrant::ROLES.include?(role)
          raise ::Disk::Refused, "Sealed items cannot be given to agents" if node.sealed?
          raise ::Disk::Refused, "This item is in the trash" if node.trashed?
          ops.require_role!(node, role)

          grant = agent.disk_grants.find_or_initialize_by(node: node)
          grant.update!(organization_id: node.organization_id, role: role, granted_by: membership)
          ::Disk::Event.record!(::Disk::Event::ACTION_AGENT_GRANTED, actor: membership, node: node,
                                                                    agent: agent.key, role: role)
          render json: { grant: ::Disk::AgentGrantSerializer.new(grant, params: { paths: visible_paths([node]) }).to_h }
        end

        # DELETE /agents/:agent_id/grants/:node_id
        def destroy
          grant = agent.disk_grants.joins(:node).find_by!(disk_nodes: { key: ::Disk::Node.key_for(params[:node_id]) })
          grant.destroy!
          ::Disk::Event.record!(::Disk::Event::ACTION_AGENT_UNGRANTED, actor: membership, node: grant.node,
                                                                      agent: agent.key)
          head :no_content
        end

        private

        def agent = @agent ||= current_organization.agents.find_by!(key: params[:agent_id].to_s)
      end
    end
  end
end
