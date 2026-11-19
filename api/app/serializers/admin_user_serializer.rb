# A user as seen by a cross-domain admin: identity plus their memberships within
# the domains the acting admin manages (never memberships in other admins' orgs).
# The managed-membership subset is passed in via params[:memberships].
class AdminUserSerializer < ::ApplicationSerializer
  attributes :username, :display_name, :billing_email

  attribute :avatar_url do |user|
    next nil if user.avatar_url.blank?

    user.avatar_url.start_with?("http") ? user.avatar_url : UserSerializer.avatar_url(user, org_key: params&.dig(:avatar_org_key))
  end

  # One row per domain the admin manages that this user belongs to.
  attribute :memberships do |_user|
    Array(params&.dig(:memberships)).map do |m|
      {
        id: m.key,
        role: m.role,
        status: m.status,
        email_addresses: m.email_addresses,
        created_at: m.created_at,
        organization: {
          id: m.organization.key,
          name: m.organization.name,
          domain: m.organization.default_domain&.name,
          slug: m.organization.slug,
          status: m.organization.default_domain&.status
        }
      }
    end
  end
end
