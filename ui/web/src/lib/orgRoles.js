// Organization membership roles — single source for the role enum (mirrors the
// API's Membership roles). Order is significant: highest privilege first.
export const ORG_ROLES = ['owner', 'admin', 'member'];

// Roles that confer admin rights (mirrors Membership::ADMIN_ROLES).
export const ADMIN_ROLES = ['owner', 'admin'];

export const isAdminRole = (role) => ADMIN_ROLES.includes(role);
export const isOwnerRole = (role) => role === 'owner';

// Grant ceiling (mirrors Membership#can_grant_role?): admins can only grant the
// member role; owners can grant any role; members can grant nothing.
export function canGrantRole(actorRole, targetRole) {
  if (!isAdminRole(actorRole)) return false;
  if (isOwnerRole(actorRole)) return true;
  return targetRole === 'member';
}

// The role options an actor may pick when inviting / changing a role.
export const grantableRoles = (actorRole) =>
  ORG_ROLES.filter((r) => canGrantRole(actorRole, r));

// Whether an actor may manage (change the role of) a target membership — mirrors
// the members_controller guard: an owner manages anyone; an admin only ranks
// below them; a member none. Self is handled by the caller (you can't change
// your own role). ORG_ROLES is ordered highest-privilege first, so a larger
// index means a lower rank.
export function canManageMember(actorRole, targetRole) {
  if (isOwnerRole(actorRole)) return true;
  if (!isAdminRole(actorRole)) return false;
  return ORG_ROLES.indexOf(targetRole) > ORG_ROLES.indexOf(actorRole);
}

// The admin console is for owners and admins. Someone with no org yet still gets it:
// that is where a new signup adds their first domain. Mirrors the AppSwitcher gate.
export const canUseConsole = (organizations) =>
  !organizations?.length || organizations.some((o) => isAdminRole(o.role));
