module Disk
  # A named member's access to a node and everything beneath it.
  class Grant < ApplicationRecord
    key_prefix "dgr"

    ROLES = [Disk::ROLE_VIEW, Disk::ROLE_EDIT].freeze

    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node"
    belongs_to :membership
    belongs_to :granted_by, class_name: "Membership", foreign_key: :granted_by_membership_id, optional: true

    validates :role, inclusion: { in: ROLES }
    validates :membership_id, uniqueness: { scope: :node_id }
  end
end
