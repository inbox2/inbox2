# Metadata-only view for the /console management card and the client's "what's
# backed up?" listing. E4 minimal I/O — NEVER expose `blob`/`blob_nonce` here.
# The ciphertext is returned only by the dedicated restore fetch
# (StoredCredentialBlobSerializer).
class StoredCredentialSerializer < ::ApplicationSerializer
  attributes :provider, :external_email, :blob_version, :created_at, :updated_at
end
