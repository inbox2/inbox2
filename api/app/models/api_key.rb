class ApiKey < ApplicationRecord
  key_prefix "ak"

  SCOPE_READ = "read".freeze
  SCOPE_WRITE = "write".freeze
  SCOPES = [SCOPE_READ, SCOPE_WRITE].freeze
  SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

  belongs_to :user

  validates :name, presence: true
  validates :token_digest, presence: true
  validates :prefix, presence: true, uniqueness: true
  validate :scopes_are_known

  before_validation :generate_token, on: :create

  attr_accessor :raw_token

  def self.authenticate(token)
    return nil unless token&.start_with?("ink_")

    key = find_by(prefix: token[0..7])
    return nil unless key
    return nil if key.expires_at&.past?

    # Constant-time comparison — the prefix lookup narrows to one row, so a
    # plain `==` on the digest would leak it byte-by-byte via timing.
    if ActiveSupport::SecurityUtils.secure_compare(key.token_digest, Digest::SHA256.hexdigest(token))
      key.touch(:last_used_at)
      key
    end
  end

  # Whether this key may perform a request of the given HTTP method. An empty
  # scopes array means a legacy/full-access key (backwards compatible). A key
  # scoped to read-only may only make safe (non-mutating) requests.
  def allows_request?(http_method)
    return true if scopes.blank?
    return true if scopes.include?(SCOPE_WRITE)

    scopes.include?(SCOPE_READ) && SAFE_METHODS.include?(http_method.to_s.upcase)
  end

  private

  def scopes_are_known
    invalid = Array(scopes) - SCOPES
    errors.add(:scopes, "contains unknown values: #{invalid.join(', ')}") if invalid.any?
  end

  def generate_token
    self.raw_token = "ink_#{SecureRandom.hex(24)}"
    self.prefix = raw_token[0..7]
    self.token_digest = Digest::SHA256.hexdigest(raw_token)
  end
end
