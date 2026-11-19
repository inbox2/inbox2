# A grant giving one org membership access to one domain's slice of the shared
# org pool. With membership.all_domains = false, a member sees only the pool
# conversations for the domains they hold a grant on (plus anything directly
# assigned/granted to them). See Conversation.visible_to.
class MembershipDomain < ApplicationRecord
  belongs_to :membership
  belongs_to :domain

  validates :domain_id, uniqueness: { scope: :membership_id }
  validate :domain_in_membership_org

  private

  def domain_in_membership_org
    return if domain.nil? || membership.nil?
    return if domain.organization_id == membership.organization_id

    errors.add(:domain, "must belong to the member's organization")
  end
end
