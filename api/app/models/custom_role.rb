class CustomRole < ApplicationRecord
  key_prefix "role"
  belongs_to :organization
  validates :name, presence: true
end
