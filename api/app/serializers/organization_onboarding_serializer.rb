class OrganizationOnboardingSerializer
  include Alba::Resource

  attribute :checklist do |org|
    {
      domain_added: true,
      dns_verified: dns_verified?(org),
      members_invited: members_invited?(org),
      first_rule_created: first_rule_created?(org),
      test_email_received: false
    }
  end

  attribute :completed do |org|
    [true, dns_verified?(org), members_invited?(org), first_rule_created?(org)].count(true)
  end

  attribute :total do |_org|
    5
  end

  private

  def dns_verified?(org)
    dom = org.default_domain
    dom.present? && dom.status != Domain::STATUS_PENDING_DNS
  end

  def members_invited?(org)
    org.memberships.active.count > 1
  end

  def first_rule_created?(org)
    org.rules.any?
  end
end
