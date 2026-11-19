class DeliveryChannel < ApplicationRecord
  key_prefix "dch"

  # `builtin` = inbox2's own deliverability (DKIM-signed, delivered by the Go MTA
  # over SMTP). Everything else is a customer-owned ESP the org points outbound
  # mail at instead — `smtp_relay` is a generic SMTP endpoint; the rest are
  # provider HTTP APIs (see DeliveryProviders). One org runs one of these at a
  # time, marked is_default; builtin always exists as the fallback.
  KINDS = %w[builtin smtp_relay ses sendgrid mailgun postmark messy].freeze
  KIND_BUILTIN = "builtin".freeze
  KIND_SMTP_RELAY = "smtp_relay".freeze
  KIND_SES = "ses".freeze
  KIND_SENDGRID = "sendgrid".freeze
  KIND_MAILGUN = "mailgun".freeze
  KIND_POSTMARK = "postmark".freeze
  KIND_MESSY = "messy".freeze
  # Every kind except the inbox2 built-in — a customer-configured ESP.
  CUSTOM_KINDS = (KINDS - [KIND_BUILTIN]).freeze

  STATUSES = %w[active error disabled].freeze
  STATUS_ACTIVE = "active".freeze
  STATUS_ERROR = "error".freeze
  STATUS_DISABLED = "disabled".freeze

  belongs_to :organization
  has_many :delivery_statuses, dependent: :nullify

  validates :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: STATUS_ACTIVE) }

  def builtin?
    kind == KIND_BUILTIN
  end

  def custom?
    CUSTOM_KINDS.include?(kind)
  end

  def self.ensure_builtin(organization)
    organization.delivery_channels.find_or_create_by!(kind: DeliveryChannel::KIND_BUILTIN) do |ch|
      ch.name = "Inbox2 SMTP"
      ch.is_default = true
      ch.status = STATUS_ACTIVE
    end
  end

  # The channel outbound mail should actually flow through for this org: the
  # active default if one is set, otherwise the built-in. Guarantees the built-in
  # exists so the publisher always has a channel to fall back to.
  def self.active_for(organization)
    builtin = ensure_builtin(organization)
    default = organization.delivery_channels.active.find_by(is_default: true)
    default || builtin
  end
end
