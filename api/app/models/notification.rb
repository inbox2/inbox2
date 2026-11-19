class Notification < ApplicationRecord
  key_prefix "ntf"

  KINDS = %w[assignment mention access_grant reply delivery_failure disk_shared disk_quota disk_plan].freeze
  KIND_ASSIGNMENT = "assignment".freeze
  KIND_MENTION = "mention".freeze
  KIND_ACCESS_GRANT = "access_grant".freeze
  KIND_REPLY = "reply".freeze
  KIND_DELIVERY_FAILURE = "delivery_failure".freeze
  KIND_DISK_SHARED = "disk_shared".freeze
  KIND_DISK_QUOTA = "disk_quota".freeze
  KIND_DISK_PLAN = "disk_plan".freeze

  belongs_to :user
  belongs_to :organization
  belongs_to :conversation, optional: true
  belongs_to :actor, class_name: "Membership", foreign_key: :actor_membership_id, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :title, presence: true

  scope :unread, -> { where(read: false) }
  scope :recent, -> { order(created_at: :desc) }
end
