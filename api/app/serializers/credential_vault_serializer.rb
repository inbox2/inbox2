# Vault metadata for a device to unlock the credential backup. Every field is
# opaque to the server: the two wrapped DEK copies can't be unwrapped without the
# user's inbox2 password or the originating device's keychain key, and the salt +
# Argon params only describe how to derive the (still-unknown) KEK. Exposed so a
# new device can fetch them and unwrap locally.
class CredentialVaultSerializer < ::ApplicationSerializer
  attributes :device_wrapped_dek, :passphrase_wrapped_dek, :argon_salt,
    :argon_params, :created_at, :updated_at
end
