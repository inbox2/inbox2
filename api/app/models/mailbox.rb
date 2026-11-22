# A member's address on a specific domain (membership × domain). The address unit
# under the multi-domain model: a member has no address until a Mailbox exists.
# Address = local_part@domain.name; local_part is unique per domain.
class Mailbox < ApplicationRecord
  key_prefix "mbx"

  belongs_to :membership
  belongs_to :domain

  validates :local_part, presence: true, format: { with: Membership::LOCAL_PART_FORMAT }
  validates :local_part, uniqueness: { scope: :domain_id, case_sensitive: false }
  validate :domain_belongs_to_membership_org
  validate :not_granted_to_another_member
  validate :not_a_shared_address

  before_validation { self.local_part = local_part.downcase.strip if local_part.present? }

  delegate :organization, :organization_id, to: :domain, allow_nil: true

  # Plus addressing: waseem+receipts@ is waseem@'s mail. The part after the
  # first "+" is a tag (a subfolder), never part of whose address it is.
  TAG_SEPARATOR = "+".freeze

  def self.base_local_part(local) = local.to_s.split(TAG_SEPARATOR, 2).first.to_s
  def self.tag_of(local) = local.to_s.split(TAG_SEPARATOR, 2)[1].presence

  def email_address
    "#{local_part}@#{domain&.name}"
  end

  private

  # Someone already sends as this address (Membership#send_as_addresses): giving
  # it to another person as their own mailbox would split one address two ways.
  def not_granted_to_another_member
    return if domain.nil? || membership.nil? || local_part.blank?

    taken = Membership.where(organization_id: domain.organization_id).where.not(id: membership.id)
      .exists?(["? = ANY(send_as_addresses)", email_address.downcase])
    errors.add(:local_part, "is already granted to someone as a send-as address") if taken
  end

  # info@ on the domain's shared list is the team's address, not one person's.
  def not_a_shared_address
    errors.add(:local_part, "is a shared address on this domain") if domain&.shared_local?(local_part)
  end

  # A mailbox must live on a domain owned by the same org as its membership.
  def domain_belongs_to_membership_org
    return if domain.nil? || membership.nil?

    errors.add(:domain, "must belong to the membership's organization") if domain.organization_id != membership.organization_id
  end
end
