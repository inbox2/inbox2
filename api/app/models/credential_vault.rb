# Per-user vault metadata for the zero-knowledge credential backup (see
# docs/E2EE.md). Holds the DEK wrapped two ways — under the device's OS-keychain
# key (`device_wrapped_dek`, for transparent same-device unlock) and under a KEK
# derived from the user's inbox2 password via Argon2id (`passphrase_wrapped_dek`,
# for cross-device restore) — plus the `argon_salt` + `argon_params` needed to
# re-derive that KEK on a new device.
#
# Every column is opaque to the server: it can unwrap NEITHER copy (no password,
# no device key). The vault is useless without the user's inbox2 password or a
# still-logged-in device. One vault per user.
class CredentialVault < ApplicationRecord
  include HasPublicId
  key_prefix "vlt"

  belongs_to :user
end
