module Disk
  class GrantSerializer < ::ApplicationSerializer
    attributes :role, :created_at

    attribute :node_id do |g|
      g.node.key
    end

    one :membership, resource: Disk::MemberRefSerializer
    one :granted_by, resource: Disk::MemberRefSerializer
  end
end
