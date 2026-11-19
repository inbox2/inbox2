module Disk
  # An agent's grant. params: paths ({ node id => visible chain }).
  class AgentGrantSerializer
    include Alba::Resource

    attributes :role, :created_at

    attribute :agent_id do |g|
      g.agent.key
    end

    attribute :node do |g|
      Disk::NodeWithPathSerializer.new(g.node, params: { path: params[:paths]&.[](g.node_id) || [] }).to_h
    end

    one :granted_by, resource: Disk::MemberRefSerializer
  end
end
