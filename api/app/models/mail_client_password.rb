# An app password for a mail client (docs/Mail-Clients.md). The account
# password cannot be used there: sign-in may need a passkey, a TOTP code or
# SAML, none of which IMAP can ask for. It opens one membership's own mailbox
# over IMAP and SMTP submission, and nothing else in the API.
class MailClientPassword < ApplicationRecord
  key_prefix "mcp"

  TOKEN_PREFIX = "imc_".freeze
  LOOKUP_LENGTH = 12

  belongs_to :membership

  validates :name, presence: true
  before_validation :generate_token, on: :create

  attr_accessor :raw_token

  def self.authenticate(token)
    return nil unless token&.start_with?(TOKEN_PREFIX)

    record = find_by(prefix: token[0, LOOKUP_LENGTH])
    return nil unless record
    return nil unless ActiveSupport::SecurityUtils.secure_compare(record.token_digest, Digest::SHA256.hexdigest(token))

    # Mail clients poll every few seconds; once an hour is enough to show use.
    record.touch(:last_used_at) if record.last_used_at.nil? || record.last_used_at < 1.hour.ago
    record
  end

  private

  def generate_token
    self.raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(16)}"
    self.prefix = raw_token[0, LOOKUP_LENGTH]
    self.token_digest = Digest::SHA256.hexdigest(raw_token)
  end
end
