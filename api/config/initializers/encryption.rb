# spec 11.3.1 — Encryption at rest for stored mail and attachments
#
# Rails 8 provides encrypted attributes via ActiveRecord::Encryption.
# Enable encryption for sensitive fields:
#   - Message body content
#   - Attachment references
#   - Webhook secrets
#   - API credentials
#
# The encryption key is derived from Rails.application.credentials.secret_key_base.
# In production, ensure RAILS_MASTER_KEY is set and the credentials file is encrypted.
#
# Usage in models:
#   encrypts :body_plain, :body_html  (on Message)
#   encrypts :secret                   (on Webhook)
#   encrypts :config                   (on DeliveryChannel — contains SMTP passwords)

primary_key      = Rails.application.credentials.dig(:active_record_encryption, :primary_key)
deterministic_key = Rails.application.credentials.dig(:active_record_encryption, :deterministic_key)
derivation_salt   = Rails.application.credentials.dig(:active_record_encryption, :key_derivation_salt)

# Never fall back to hardcoded keys in production — encrypting credentials (e.g.
# the TOTP seed) with a publicly-known key is equivalent to not encrypting them.
# Skipped during image builds (assets:precompile runs with SECRET_KEY_BASE_DUMMY
# and no master key, so credentials can't be decrypted yet — the real check
# happens at runtime boot, when RAILS_MASTER_KEY is present).
building_image = ENV["SECRET_KEY_BASE_DUMMY"].present?
if Rails.env.production? && !building_image && [primary_key, deterministic_key, derivation_salt].any?(&:blank?)
  raise "Active Record encryption keys are missing. Set active_record_encryption.{primary_key,deterministic_key,key_derivation_salt} in Rails credentials."
end

Rails.application.config.active_record.encryption.primary_key = primary_key || "dev-primary-key"
Rails.application.config.active_record.encryption.deterministic_key = deterministic_key || "dev-deterministic-key"
Rails.application.config.active_record.encryption.key_derivation_salt = derivation_salt || "dev-key-derivation-salt"

# Allow reading rows written before encryption was enabled (e.g. existing
# plaintext totp_secret values) so the rollout doesn't error on read. New writes
# are always encrypted.
Rails.application.config.active_record.encryption.support_unencrypted_data = true
