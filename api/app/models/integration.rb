class Integration < ApplicationRecord
  key_prefix "int"

  PROVIDERS = %w[slack teams zapier make crm_generic].freeze
  PROVIDER_SLACK = "slack".freeze
  PROVIDER_TEAMS = "teams".freeze
  PROVIDER_ZAPIER = "zapier".freeze
  PROVIDER_MAKE = "make".freeze
  PROVIDER_CRM = "crm_generic".freeze

  STATUSES = %w[active paused error disconnected].freeze
  STATUS_ACTIVE = "active".freeze
  STATUS_PAUSED = "paused".freeze
  STATUS_ERROR = "error".freeze
  STATUS_DISCONNECTED = "disconnected".freeze

  EVENTS = %w[message.received message.sent conversation.created conversation.assigned conversation.closed].freeze

  # `config` is a free-form JSON hash, but for Slack/Zapier/Make the incoming
  # webhook URL it holds is *itself* a bearer secret (anyone with the URL can post
  # into the channel). Redact values whose key looks secret-bearing on API reads,
  # and ignore the redaction sentinel on writes so a round-tripped read can't wipe
  # the stored secret.
  SECRET_CONFIG_KEY_PATTERN = /url|token|secret|key|password|signature/i
  REDACTED = "••••••".freeze

  belongs_to :organization

  validates :name, presence: true
  validates :provider, inclusion: { in: PROVIDERS }
  validates :status, inclusion: { in: STATUSES }
  validate :events_valid

  scope :active, -> { where(status: STATUS_ACTIVE) }

  def store_tokens!(access_token:, refresh_token: nil, expires_at: nil)
    update!(
      access_token_digest: Digest::SHA256.hexdigest(access_token),
      refresh_token_digest: refresh_token ? Digest::SHA256.hexdigest(refresh_token) : nil,
      token_expires_at: expires_at
    )
  end

  def token_expired?
    token_expires_at.present? && token_expires_at.past?
  end

  # Config with secret-bearing values masked, for safe exposure in API reads.
  def display_config
    src = config.is_a?(Hash) ? config : {}
    src.each_with_object({}) do |(k, v), out|
      out[k] = secret_config_key?(k) && v.present? ? REDACTED : v
    end
  end

  # Merge incoming config over the stored config, dropping any value that is the
  # redaction sentinel (i.e. an unchanged secret the client echoed back) so an
  # update never overwrites a real secret with the mask.
  def merge_config(incoming)
    base = config.is_a?(Hash) ? config : {}
    base.merge((incoming || {}).reject { |_k, v| v.to_s == REDACTED })
  end

  def secret_config_key?(key)
    key.to_s.match?(SECRET_CONFIG_KEY_PATTERN)
  end

  private

  def events_valid
    return if events.blank?

    invalid = events - EVENTS
    errors.add(:events, "contains invalid events: #{invalid.join(', ')}") if invalid.any?
  end
end
