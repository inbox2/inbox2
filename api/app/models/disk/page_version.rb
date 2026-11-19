module Disk
  # A page as it was at a revision (spec F6 history). Restoring one is an
  # ordinary save of its content from the editor, so live collaborators
  # converge on it instead of being overwritten.
  class PageVersion < ApplicationRecord
    belongs_to :organization
    belongs_to :node, class_name: "Disk::Node"
    belongs_to :author, class_name: "Membership", foreign_key: :author_membership_id, optional: true
  end
end
