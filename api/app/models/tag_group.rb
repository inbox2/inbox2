class TagGroup < ApplicationRecord
  key_prefix "tg"
  belongs_to :organization
  has_many :tags
  validates :name, presence: true
  scope :ordered, -> { order(position: :asc) }
end
