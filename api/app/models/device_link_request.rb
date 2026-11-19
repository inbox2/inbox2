# A short-lived, PKCE-bound authorization code for the "link this device to your
# inbox2 account" flow (loopback-redirect, OAuth-style). The native client
# (desktop/iOS/Android) generates a PKCE verifier, opens the web approval page in
# the system browser, and the logged-in user approves. Approval mints one of
# these (bound to the approving user + the client's code_challenge); the client
# then redeems the one-time code + verifier for a device-scoped ink_ ApiKey.
#
# Mirrors the Session/ApiKey token pattern: a raw "dlc_" code shown once, stored
# only as a SHA256 digest with an indexed prefix for lookup. Single-use + short
# TTL. See docs/Device-Link.md.
class DeviceLinkRequest < ApplicationRecord
  key_prefix "dlr"

  STATUS_PENDING = "pending".freeze
  STATUS_CONSUMED = "consumed".freeze
  STATUSES = [STATUS_PENDING, STATUS_CONSUMED].freeze

  PLATFORM_DESKTOP = "desktop".freeze
  PLATFORM_IOS = "ios".freeze
  PLATFORM_ANDROID = "android".freeze
  PLATFORM_CLI = "cli".freeze
  PLATFORMS = [PLATFORM_DESKTOP, PLATFORM_IOS, PLATFORM_ANDROID, PLATFORM_CLI].freeze

  # Only PKCE S256 is accepted — never the insecure "plain" method.
  CHALLENGE_METHOD = "S256".freeze
  CODE_TTL = 5.minutes
  CODE_PREFIX = "dlc_".freeze

  belongs_to :user

  validates :code_digest, :prefix, :code_challenge, :redirect_uri, :device_name, :status, presence: true
  validates :prefix, uniqueness: true
  validates :platform, inclusion: { in: PLATFORMS }
  validates :status, inclusion: { in: STATUSES }
  validates :code_challenge_method, inclusion: { in: [CHALLENGE_METHOD] }
  validate :redirect_uri_is_loopback

  before_validation :generate_code, on: :create
  before_validation :set_defaults, on: :create

  attr_accessor :raw_code

  # Resolve a still-pending, unexpired request by its raw one-time code. Constant
  # time on the digest (the prefix lookup narrows to one row).
  def self.authenticate(code)
    return nil unless code&.start_with?(CODE_PREFIX)

    req = find_by(prefix: code[0..11], status: STATUS_PENDING)
    return nil unless req
    return nil if req.expires_at&.past?

    if ActiveSupport::SecurityUtils.secure_compare(req.code_digest, Digest::SHA256.hexdigest(code))
      req
    end
  end

  # Verify the client's PKCE code_verifier against the stored S256 challenge.
  def verifier_matches?(code_verifier)
    return false if code_verifier.blank?

    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier.to_s), padding: false)
    ActiveSupport::SecurityUtils.secure_compare(code_challenge, challenge)
  end

  def consume!
    update!(status: STATUS_CONSUMED)
  end

  private

  def set_defaults
    self.status ||= STATUS_PENDING
    self.code_challenge_method = CHALLENGE_METHOD if code_challenge_method.blank?
    self.expires_at ||= CODE_TTL.from_now
  end

  def generate_code
    self.raw_code = "#{CODE_PREFIX}#{SecureRandom.hex(24)}"
    self.prefix = raw_code[0..11]
    self.code_digest = Digest::SHA256.hexdigest(raw_code)
  end

  # The redirect target is always the client's own loopback listener. Restricting
  # it to 127.0.0.1/localhost/::1 prevents the approval code being exfiltrated to
  # an attacker-controlled URL (open-redirect / code interception).
  def redirect_uri_is_loopback
    uri = URI.parse(redirect_uri.to_s)
    loopback = %w[127.0.0.1 localhost ::1].include?(uri.host)
    unless %w[http https].include?(uri.scheme) && loopback
      errors.add(:redirect_uri, "must be a loopback address")
    end
  rescue URI::InvalidURIError
    errors.add(:redirect_uri, "is invalid")
  end
end
