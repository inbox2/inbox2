# One member's access to a DomainKey (docs/E2EE.md): the domain's secret key
# sealed (crypto_box_seal) to the membership's user identity public key. Opaque
# to the server — only that member's unwrapped identity key can open it. Issued
# per (domain_key, membership); removing the membership drops its grants, and a
# lost identity key is recovered by another member re-issuing a fresh grant.
class DomainKeyGrant < ApplicationRecord
  key_prefix "dkg"

  belongs_to :domain_key
  belongs_to :membership

  validates :sealed_secret_key, presence: true
  validates :membership_id, uniqueness: { scope: :domain_key_id }
end
