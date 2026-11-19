module Disk
  class ShareMembership < ApplicationRecord
    belongs_to :organization
    belongs_to :share, class_name: "Disk::Share"
    belongs_to :membership

    validates :role, inclusion: { in: Disk::ROLES }
    validates :membership_id, uniqueness: { scope: :share_id }
  end
end
