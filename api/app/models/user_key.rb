# A user's E2EE identity keypair (docs/E2EE.md Phase A/B). The server stores the
# public key plus the private key wrapped TWO ways — under an Argon2id
# password-KEK (`encrypted_private_key`) and under the generated Diceware
# recovery passphrase (`recovery_encrypted_private_key`). Both blobs are opaque:
# the server can unwrap neither, so it can never read sealed mail or "reset" a
# lost passphrase. `kdf_params` carries the Argon2id salt/cost settings needed to
# re-derive the KEKs client-side. One identity per user.
class UserKey < ApplicationRecord
  key_prefix "ukey"

  belongs_to :user

  validates :public_key, presence: true
  validates :encrypted_private_key, presence: true
  validates :user_id, uniqueness: true
end
