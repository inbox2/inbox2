# One received deliverability aggregate report (TODO 46.10): a TLS-RPT JSON
# report (RFC 8460) or a DMARC rua XML report (RFC 7489), parsed down to the
# counts that matter. failure_count > 0 means a receiving provider saw our mail
# fail auth or TLS — the earliest warning that deliverability is degrading.
class MailAuthReport < ApplicationRecord
  key_prefix "mar"

  KINDS = %w[tlsrpt dmarc].freeze
  KIND_TLSRPT = "tlsrpt".freeze
  KIND_DMARC = "dmarc".freeze

  belongs_to :organization

  validates :kind, inclusion: { in: KINDS }

  scope :recent, -> { order(created_at: :desc) }
  scope :with_failures, -> { where("failure_count > 0") }
end
