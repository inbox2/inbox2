# A platform SaaS operator, identified by the SHA-256 fingerprint of their
# TLS client certificate. The cert is the sole identity: there is no password and
# no User link. mTLS (terminated at the ingress) plus the IP allowlist are the
# gate; this row maps a verified fingerprint to a named operator for audit.
# Revoked by stamping revoked_at. See docs/SaaS.md.
class AdminCredential < ApplicationRecord
  key_prefix "adm"

  has_many :saas_audit_logs, dependent: :nullify

  validates :label, presence: true
  validates :cert_fingerprint, presence: true, uniqueness: true

  normalizes :cert_fingerprint, with: ->(fp) { normalize_fingerprint(fp) }

  scope :active, -> { where(revoked_at: nil) }

  # Resolve a verified client-cert fingerprint to an active operator (or nil).
  def self.authenticate(fingerprint)
    return nil if fingerprint.blank?

    active.find_by(cert_fingerprint: normalize_fingerprint(fingerprint))
  end

  # Fingerprints arrive in assorted shapes from proxies (with colons, lower/upper
  # case, an optional "SHA256:" prefix). Canonicalise to lowercase hex so lookups
  # match regardless of source format.
  def self.normalize_fingerprint(raw)
    raw.to_s.strip.sub(/\Asha256:/i, "").delete(":").downcase
  end

  def active?
    revoked_at.nil?
  end

  def touch_usage!(ip)
    update_columns(last_used_at: Time.current, last_used_ip: ip)
  end
end
