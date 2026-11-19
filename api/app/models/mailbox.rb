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

  before_validation { self.local_part = local_part.downcase.strip if local_part.present? }

  delegate :organization, :organization_id, to: :domain, allow_nil: true

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

  # A mailbox must live on a domain owned by the same org as its membership.
  def domain_belongs_to_membership_org
    return if domain.nil? || membership.nil?

    errors.add(:domain, "must belong to the membership's organization") if domain.organization_id != membership.organization_id
  end
end
