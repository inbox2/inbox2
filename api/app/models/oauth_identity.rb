class OauthIdentity < ApplicationRecord
  PROVIDERS = %w[google microsoft].freeze
  PROVIDER_GOOGLE = "google".freeze
  PROVIDER_MICROSOFT = "microsoft".freeze

  belongs_to :user

  validates :provider, inclusion: { in: PROVIDERS }
  validates :uid, presence: true
  validates :uid, uniqueness: { scope: :provider }

  def store_tokens!(access_token:, refresh_token: nil, expires_at: nil)
    update!(
      access_token_digest: Digest::SHA256.hexdigest(access_token),
      refresh_token_digest: refresh_token ? Digest::SHA256.hexdigest(refresh_token) : refresh_token_digest,
      token_expires_at: expires_at
    )
  end
end
