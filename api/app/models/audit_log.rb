class AuditLog < ApplicationRecord
  key_prefix "aud"

  belongs_to :organization
  belongs_to :membership, optional: true

  validates :action, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
