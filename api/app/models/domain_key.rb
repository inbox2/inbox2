# A domain's versioned E2EE sealing keypair (docs/E2EE.md). The MX seals each
# inbound message's DEK to the current (non-retired, highest-version) public key;
# members hold the matching secret key only via sealed DomainKeyGrant blobs. The
# server stores ONLY the public key — never the secret. Member removal retires
# the version (`retired_at`) and mints v+1 with fresh grants (rotation phase).
class DomainKey < ApplicationRecord
  key_prefix "dkey"

  belongs_to :domain
  has_many :grants, class_name: "DomainKeyGrant", dependent: :destroy

  validates :public_key, presence: true
  validates :version, presence: true, numericality: { only_integer: true, greater_than: 0 },
                      uniqueness: { scope: :domain_id }

  scope :active, -> { where(retired_at: nil) }

  def retired?
    retired_at.present?
  end
end
