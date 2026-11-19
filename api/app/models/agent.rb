class Agent < ApplicationRecord
  key_prefix "agt"

  STATUSES = %w[active disabled].freeze
  STATUS_ACTIVE = "active".freeze
  STATUS_DISABLED = "disabled".freeze
  MAIL_PERMISSIONS = %w[read reply tag set_status assign grant_access].freeze
  # Disk over MCP (docs/plans/disk-build.md section 9c). Never granted by default.
  DISK_READ = "disk_read".freeze
  DISK_WRITE = "disk_write".freeze
  DISK_MANAGE = "disk_manage".freeze
  DISK_PERMISSIONS = [DISK_READ, DISK_WRITE, DISK_MANAGE].freeze
  PERMISSIONS = (MAIL_PERMISSIONS + DISK_PERMISSIONS).freeze

  belongs_to :organization
  belongs_to :membership
  belongs_to :supervisor, class_name: "Membership", foreign_key: :supervisor_membership_id, optional: true
  has_many :run_logs, class_name: "AgentRunLog", dependent: :destroy
  has_many :disk_grants, class_name: "Disk::AgentGrant", dependent: :delete_all

  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: STATUS_ACTIVE) }

  # Resolve an active agent from its `agt_` API credential. Lookup is by digest
  # (no plaintext stored), so the DB index does the constant-time match.
  def self.authenticate(token)
    return nil unless token&.start_with?("agt_")

    active.find_by(api_credential_digest: Digest::SHA256.hexdigest(token))
  end

  def permits?(permission)
    permissions.include?(permission.to_s)
  end

  def generate_credential!
    raw = "agt_#{SecureRandom.hex(24)}"
    update!(api_credential_digest: Digest::SHA256.hexdigest(raw))
    raw
  end

  def rate_limited?
    return false if rate_limit.zero?

    runs_this_hour = run_logs.where("created_at > ?", 1.hour.ago).count
    runs_this_hour >= rate_limit
  end

  def spend_limited?
    return false if spend_limit_cents.zero?

    total_spend_cents >= spend_limit_cents
  end

  def record_run!(action:, conversation: nil, status:, duration_ms: nil, cost_cents: 0, metadata: {}, error_message: nil)
    log = run_logs.create!(
      action: action,
      conversation: conversation,
      status: status,
      duration_ms: duration_ms,
      cost_cents: cost_cents,
      metadata: metadata,
      error_message: error_message
    )

    increment!(:total_runs)
    increment!(:total_spend_cents, cost_cents) if cost_cents > 0

    log
  end
end
