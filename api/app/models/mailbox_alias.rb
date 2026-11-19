# Disposition for a *retired* mailbox local-part on a domain. Created when a user
# is offboarded from a domain so their old address keeps behaving predictably:
#   - reroute → future mail to local_part@domain is accepted and the chosen
#     target membership is granted access to the resulting conversation.
#   - bounce  → future mail to local_part@domain is rejected at ingest.
# Consulted by InboundMailProcessor (which otherwise ignores the local-part).
class MailboxAlias < ApplicationRecord
  key_prefix "mbxalias"

  MODE_REROUTE = "reroute".freeze
  MODE_BOUNCE = "bounce".freeze
  MODES = [MODE_REROUTE, MODE_BOUNCE].freeze

  belongs_to :organization
  belongs_to :domain, optional: true
  # Only set for reroute — the membership that now receives this mailbox's mail.
  belongs_to :target_membership, class_name: "Membership", optional: true

  validates :local_part, presence: true,
    format: { with: Membership::LOCAL_PART_FORMAT },
    uniqueness: { scope: :domain_id, case_sensitive: false }
  validates :mode, inclusion: { in: MODES }
  validates :target_membership, presence: true, if: -> { mode == MODE_REROUTE }

  before_validation { self.local_part = local_part.downcase.strip if local_part.present? }

  def reroute? = mode == MODE_REROUTE
  def bounce?  = mode == MODE_BOUNCE
end
