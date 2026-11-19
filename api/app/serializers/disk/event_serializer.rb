module Disk
  class EventSerializer < ::ApplicationSerializer
    attributes :action, :detail, :created_at

    attribute :node_id do |e|
      e.node&.key
    end

    attribute :share_id do |e|
      e.share&.key
    end

    # Set when a visitor used a public link; actor is then null.
    attribute :link_id do |e|
      e.link&.key
    end

    # Set when an agent acted; actor is then its membership, named for the agent.
    attribute :agent_id do |e|
      e.actor_agent&.key
    end

    one :actor, resource: Disk::MemberRefSerializer
  end
end
