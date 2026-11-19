class Contact < ApplicationRecord
  key_prefix "ct"
  belongs_to :organization
  validates :email, presence: true, uniqueness: { scope: :organization_id }
end
