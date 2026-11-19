# The current user's own E2EE identity key (docs/E2EE.md). Only ever rendered
# to its owner — the wrapped private blobs are opaque to the server but still
# private material for offline attack, so no other user (or list view) sees
# them. Other members get the PUBLIC key via the domain e2ee directory.
class UserKeySerializer < ::ApplicationSerializer
  attributes :public_key, :encrypted_private_key, :recovery_encrypted_private_key,
             :kdf_params, :created_at, :updated_at
end
