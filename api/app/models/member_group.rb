class MemberGroup < ApplicationRecord
  key_prefix "mg"
  belongs_to :organization
  validates :name, presence: true
end
