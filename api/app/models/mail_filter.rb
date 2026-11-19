class MailFilter < ApplicationRecord
  key_prefix "mf"

  KINDS = %w[blocklist allowlist junk].freeze
  KIND_BLOCKLIST = "blocklist".freeze
  KIND_ALLOWLIST = "allowlist".freeze
  # Senders the org marked as spam. Unlike the blocklist (which rejects at the
  # door), junk mail is still delivered — it just lands in Spam instead of the
  # inbox, so a false positive stays recoverable.
  KIND_JUNK = "junk".freeze

  belongs_to :organization

  # An address (name@domain.tld) or a bare domain (domain.tld) — the domain part
  # must contain at least one dot.
  VALUE_FORMAT = /\A(?:[^\s@]+@)?[^\s@.]+(?:\.[^\s@.]+)+\z/

  validates :kind, inclusion: { in: KINDS }
  validates :value, presence: true, uniqueness: { scope: :organization_id },
    format: { with: VALUE_FORMAT, message: "must be an email address or domain" }
end
