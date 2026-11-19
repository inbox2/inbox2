class Session < ApplicationRecord
  self.ignored_columns += %w[key]

  belongs_to :user

  attr_accessor :raw_token

  before_create :generate_token_digest

  scope :active, -> { where("last_active_at > ?", 30.days.ago) }

  def active?
    last_active_at.nil? || last_active_at > 30.days.ago
  end

  def self.find_by_token(raw_token)
    return nil unless raw_token.present?

    find_by(token_digest: Digest::SHA256.hexdigest(raw_token))
  end

  private

  def generate_token_digest
    raw = SecureRandom.hex(32)
    self.raw_token = raw
    self.token = raw
    self.token_digest = Digest::SHA256.hexdigest(raw)
  end

  def generate_key
    # Sessions don't use public IDs
  end
end
