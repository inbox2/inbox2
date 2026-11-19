module Disk
  # One epoch of a sealed scope; previous_key_wrapped opens the epoch before (6.5).
  class ScopeEpoch < ApplicationRecord
    self.table_name = "disk_scope_epochs"
    belongs_to :organization
    belongs_to :scope_node, class_name: "Disk::Node"
    belongs_to :created_by, class_name: "Membership", foreign_key: :created_by_membership_id, optional: true
  end
end
