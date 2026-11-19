module Saas
  # Org as seen by a platform operator: identity + operational state, effective
  # plan, mailbox cap/usage and owner. Exposes only public ids (E5).
  class OrganizationSerializer < ::ApplicationSerializer
    attributes :name, :slug, :data_retention_days, :created_at

    attribute :domains do |org|
      org.domains.map { |d| { id: d.key, name: d.name, status: d.status } }
    end

    # Primary-domain mirror for back-compat with single-domain views.
    attribute :domain do |org|
      org.default_domain&.name
    end

    attribute :suspended do |org|
      org.suspended?
    end

    attributes :suspended_at, :suspended_reason

    attribute :plan do |org|
      org.effective_plan.name
    end

    # nil = inheriting (no per-org override).
    attribute :plan_override do |org|
      org.plan&.name
    end

    attribute :mailbox_limit do |org|
      org.mailbox_limit
    end

    attribute :effective_mailbox_limit do |org|
      org.effective_mailbox_limit
    end

    attribute :mailbox_count do |org|
      org.mailbox_count
    end

    attribute :owner do |org|
      next nil unless org.owner

      { id: org.owner.key, username: org.owner.username, billing_email: org.owner.billing_email }
    end
  end
end
