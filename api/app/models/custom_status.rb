class CustomStatus < ApplicationRecord
  key_prefix "cst"
  belongs_to :organization
  validates :name, presence: true, uniqueness: { scope: :organization_id }
  scope :ordered, -> { order(position: :asc) }
end
