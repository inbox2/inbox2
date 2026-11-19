# Shared org-management authority checks. The unit of tenant isolation for any
# admin action that spans more than the single `current_organization`: a user
# may only ever touch the domains they own or are an active admin of.
module ManagesOrganizations
  extend ActiveSupport::Concern

  private

  # Whether the current user may manage `org` (owner or active admin member).
  def manages?(org)
    org.owner_id == current_user.id ||
      org.memberships.exists?(user: current_user, status: Membership::STATUS_ACTIVE, role: Membership::ADMIN_ROLES)
  end

  # Whether the current user may grant `role` in `org`. Members can't grant;
  # admins grant member only; granting admin/owner requires owner.
  def can_grant_role_in?(org, role)
    return false unless manages?(org)
    return true if role == Membership::ROLE_MEMBER

    org.owner_id == current_user.id ||
      org.memberships.exists?(user: current_user, status: Membership::STATUS_ACTIVE, role: Membership::ROLE_OWNER)
  end

  # The domains (orgs) the current user manages as owner/admin. Every
  # cross-domain admin query must be scoped through this. Resolved in a single
  # query (active membership in the org, and either owning it or holding an
  # admin role there) rather than an EXISTS-per-org `manages?` loop.
  def managed_organizations
    @managed_organizations ||= begin
      ensure_owner_memberships!
      Organization
        .joins(:memberships)
        .where(memberships: { user_id: current_user.id, status: Membership::STATUS_ACTIVE })
        .where("organizations.owner_id = :uid OR memberships.role IN (:admin)",
          uid: current_user.id, admin: Membership::ADMIN_ROLES)
        .distinct
        .to_a
    end
  end

  # Self-heal: an org's owner must always hold an active `owner` membership, so
  # they manage their domain and appear in its team list. OrganizationsController#create
  # creates this, but legacy/seeded orgs (or any created outside that path) can
  # lack it — which would otherwise drop the owner out of their own admin views.
  # Idempotent: no-ops once a membership exists.
  def ensure_owner_memberships!
    missing = Organization.teams.where(owner_id: current_user.id)
      .where.not(id: Membership.where(user_id: current_user.id).select(:organization_id))
    missing.find_each do |org|
      org.memberships.create!(
        user: current_user,
        role: Membership::ROLE_OWNER,
        status: Membership::STATUS_ACTIVE
      )
    end
  end
end
