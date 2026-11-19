module Saas
  # User as seen by a platform operator: identity, their effective billing plan,
  # and every membership across all domains (no tenant scoping).
  class UserSerializer < ::ApplicationSerializer
    attributes :username, :display_name, :billing_email, :created_at

    # `.size` uses the preloaded association (see the controller `includes`)
    # rather than firing a COUNT per user.
    attribute :owned_organizations do |user|
      user.owned_organizations.size
    end

    attribute :memberships do |user|
      user.memberships.map do |m|
        {
          id: m.key,
          role: m.role,
          status: m.status,
          email_addresses: m.email_addresses,
          organization: { id: m.organization.key, name: m.organization.name, domain: m.organization.default_domain&.name }
        }
      end
    end
  end
end
