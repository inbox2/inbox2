module Disk
  # A sealed scope's key for one epoch, sealed to one key holder's identity
  # key (build guide 6.4). The server stores it and cannot open it.
  class KeyGrant < ApplicationRecord
    key_prefix "dkg"

    SEALED_KEY_BYTES = 80 # crypto_box_seal of 32 bytes: 32 + 16 + 32

    belongs_to :organization
    belongs_to :scope_node, class_name: "Disk::Node"
    belongs_to :membership
    belongs_to :granted_by, class_name: "Membership", foreign_key: :granted_by_membership_id, optional: true

    # Holders who stop being one other than by rotate (removed, disabled,
    # deleted, their C:\ reassigned) leave a key behind: every scope they held
    # a grant for must rotate before anything is written again (6.7). Call
    # inside the transaction that removes them. scope_ids narrows it to some
    # scopes. Org wipes delete the scopes first, so they never get here.
    def self.freeze_holders!(membership_ids, scope_ids: nil)
      grants = where(membership_id: membership_ids)
      grants = grants.where(scope_node_id: scope_ids) if scope_ids
      ids = grants.distinct.pluck(:scope_node_id)
      return if ids.empty?

      Disk::Node.where(id: ids).update_all(rotation_due: true)
      grants.delete_all
    end
  end
end
