# An organization's sending key (isk_…). Unlike a personal ink_ API key it
# belongs to the org, not a person, and can do one thing: use the ESP API.
class Esp::Key < ApplicationRecord
  key_prefix "ek"

  TOKEN_PREFIX = "isk_".freeze
  LOOKUP_LENGTH = 12

  belongs_to :organization
  belongs_to :created_by, class_name: "User", optional: true
  has_many :messages, class_name: "Esp::Message", foreign_key: :esp_key_id, dependent: :restrict_with_error

  validates :name, presence: true
  before_validation :generate_token, on: :create

  attr_accessor :raw_token

  scope :active, -> { where(revoked_at: nil) }

  def self.authenticate(token)
    return nil unless token&.start_with?(TOKEN_PREFIX)

    key = active.find_by(prefix: token[0, LOOKUP_LENGTH])
    return nil unless key
    return nil unless ActiveSupport::SecurityUtils.secure_compare(key.token_digest, Digest::SHA256.hexdigest(token))

    key.touch(:last_used_at)
    key
  end

  def revoked? = revoked_at.present?

  private

  def generate_token
    self.raw_token = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"
    self.prefix = raw_token[0, LOOKUP_LENGTH]
    self.token_digest = Digest::SHA256.hexdigest(raw_token)
  end
end
