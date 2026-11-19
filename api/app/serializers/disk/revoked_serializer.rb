module Disk
  # What a move to another drive or share revoked (Disk::NodeOps#revoked):
  # link ids, { node_id, member_id } grants and { node_id, agent_id } agent grants.
  class RevokedSerializer
    include Alba::Resource

    attributes :links, :grants, :agent_grants
  end
end
