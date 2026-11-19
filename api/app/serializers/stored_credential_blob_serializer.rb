# Restore fetch — returns the opaque ciphertext so a device can decrypt locally
# with the vault DEK. The blob/nonce are useless without the DEK (which the server
# never holds). Used only by StoredCredentialsController#show.
class StoredCredentialBlobSerializer < ::ApplicationSerializer
  attributes :provider, :external_email, :blob, :blob_nonce, :blob_version
end
