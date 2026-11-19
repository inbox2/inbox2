# Zero-knowledge cloud backup of an external-mailbox channel's credentials — see
# docs/E2EE.md (credential vault). The device encrypts the credential bundle
# (OAuth tokens / IMAP password / Meta secrets + account config) under a vault DEK
# and stores only the opaque ciphertext here. The server NEVER holds a usable key
# and never decrypts: `blob`/`blob_nonce` are AES-GCM ciphertext, base64-encoded.
# `provider` + `external_email` are kept plaintext (accepted metadata leak) so the
# /console management UI can show channel icons + addresses.
#
# Keyed per-user (personal mailboxes), idempotent on (user, provider, external_email)
# so re-adding the same account upserts the latest token (last-writer-wins).
class StoredCredential < ApplicationRecord
  include HasPublicId
  key_prefix "scr"

  PROVIDER_GMAIL = "gmail".freeze
  PROVIDER_MICROSOFT = "microsoft".freeze
  PROVIDER_IMAP = "imap".freeze
  PROVIDER_INSTAGRAM = "instagram".freeze
  PROVIDER_MESSENGER = "messenger".freeze
  PROVIDER_WHATSAPP = "whatsapp".freeze
  PROVIDERS = [
    PROVIDER_GMAIL, PROVIDER_MICROSOFT, PROVIDER_IMAP,
    PROVIDER_INSTAGRAM, PROVIDER_MESSENGER, PROVIDER_WHATSAPP
  ].freeze

  belongs_to :user

  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :external_email, presence: true
  validates :blob, presence: true
  validates :blob_nonce, presence: true
  validates :external_email, uniqueness: { scope: [:user_id, :provider] }
end
