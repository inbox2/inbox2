class SpaceMembership < ApplicationRecord
  key_prefix "spm"

  belongs_to :space
  belongs_to :membership

  validates :membership_id, uniqueness: { scope: :space_id }
end
