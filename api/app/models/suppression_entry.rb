# An address inbox2 must not deliver to: hard bounces, complaints (FBL/ARF), and
# addresses that exhausted retries. Sending to a known-dead or complaining
# address is what wrecks sender reputation, so OutboundMailPublisher consults
# this list before queueing and the inbound pipeline populates it from DSN
# bounces (DsnBounceParser) and feedback reports (ComplaintParser).
class SuppressionEntry < ApplicationRecord
  key_prefix "supp"

  REASONS = %w[hard_bounce complaint permanent_failure manual].freeze
  REASON_HARD_BOUNCE = "hard_bounce".freeze
  REASON_COMPLAINT = "complaint".freeze
  REASON_PERMANENT_FAILURE = "permanent_failure".freeze
  REASON_MANUAL = "manual".freeze

  belongs_to :organization

  validates :address, presence: true, uniqueness: { scope: :organization_id, case_sensitive: false }
  validates :reason, inclusion: { in: REASONS }

  before_validation :normalize_address

  # True when this org should not send to `address`.
  def self.suppressed?(organization, address)
    return false if organization.nil? || address.blank?

    where(organization: organization, address: address.to_s.strip.downcase).exists?
  end

  # Idempotently record a suppression. A stronger reason (complaint/hard bounce)
  # never gets downgraded by a later soft signal, but the detail is refreshed.
  def self.record!(organization, address, reason:, source: nil, detail: nil)
    return nil if organization.nil? || address.blank?

    normalized = address.to_s.strip.downcase
    entry = find_or_initialize_by(organization: organization, address: normalized)
    entry.reason = reason if entry.new_record?
    entry.source = source if source.present?
    entry.detail = detail if detail.present?
    entry.save!
    entry
  end

  private

  def normalize_address
    self.address = address.to_s.strip.downcase if address.present?
  end
end
