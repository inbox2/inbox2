class Signature < ApplicationRecord
  key_prefix "sig"

  belongs_to :organization
  belongs_to :membership, optional: true

  validates :name, presence: true

  scope :org_wide, -> { where(membership_id: nil) }
  scope :personal_for, ->(membership) { where(membership: membership) }
end
