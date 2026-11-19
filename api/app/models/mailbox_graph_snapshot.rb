class MailboxGraphSnapshot < ApplicationRecord
  key_prefix "mgs"

  belongs_to :organization

  validates :payload, presence: true
  validates :computed_at, presence: true
  validates :source_version, presence: true
end
