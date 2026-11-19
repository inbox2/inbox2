# Append-only record of a single platform SaaS action. Targets are stored
# by public key + type string (not an association) so the audit row survives a
# hard wipe of the org/user it refers to. See docs/SaaS.md.
class SaasAuditLog < ApplicationRecord
  key_prefix "sal"

  # Canonical action names — referenced from the controllers, never hardcoded.
  ACTION_ORG_CREATE = "org.create".freeze
  ACTION_ORG_UPDATE = "org.update".freeze
  ACTION_ORG_SUSPEND = "org.suspend".freeze
  ACTION_ORG_UNSUSPEND = "org.unsuspend".freeze
  ACTION_ORG_WIPE = "org.wipe".freeze
  ACTION_ORG_PLAN = "org.plan".freeze
  ACTION_ORG_MAILBOX_LIMIT = "org.mailbox_limit".freeze
  ACTION_ORG_DISK_QUOTA = "org.disk_quota".freeze
  ACTION_ORG_MEMBER_ADD = "org.member.add".freeze
  ACTION_ORG_MEMBER_REMOVE = "org.member.remove".freeze
  ACTION_USER_RESET_PASSWORD = "user.reset_password".freeze
  ACTION_USER_DISABLE = "user.disable".freeze
  ACTION_USER_ENABLE = "user.enable".freeze
  ACTION_USER_OFFBOARD = "user.offboard".freeze
  ACTION_WAITLIST_INVITE = "waitlist.invite".freeze

  belongs_to :admin_credential, optional: true

  validates :action, presence: true

  # Record one action. `target` may be any record with a #key (Organization,
  # User, …) or nil for account-wide actions.
  def self.record!(admin:, action:, target: nil, ip: nil, metadata: {})
    create!(
      admin_credential: admin,
      action: action,
      target_type: target&.class&.name,
      target_key: target.respond_to?(:key) ? target.key : nil,
      ip_address: ip,
      metadata: metadata || {}
    )
  end
end
