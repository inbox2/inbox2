module Disk
  # An agent's grant on a node and everything beneath it (build guide 9c).
  # Addressed by agent and node; no public id of its own.
  class AgentGrant < ApplicationRecord
    ROLES = [Disk::ROLE_VIEW, Disk::ROLE_EDIT].freeze

    belongs_to :organization
    belongs_to :agent
    belongs_to :node, class_name: "Disk::Node"
    belongs_to :granted_by, class_name: "Membership", foreign_key: :granted_by_membership_id, optional: true

    validates :role, inclusion: { in: ROLES }
    validates :node_id, uniqueness: { scope: :agent_id }
  end
end
