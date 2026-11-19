module Disk
  class Recent < ApplicationRecord
    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node"
    belongs_to :membership

    # Records an open; a repeat open moves the row back to the top.
    def self.touch!(membership, node)
      now = Time.current
      upsert({ organization_id: node.organization_id, node_id: node.id, membership_id: membership.as_holder(node).id,
               created_at: now, updated_at: now },
        unique_by: %i[node_id membership_id],
        on_duplicate: Arel.sql("created_at = EXCLUDED.created_at, updated_at = EXCLUDED.updated_at"))
    end
  end
end
