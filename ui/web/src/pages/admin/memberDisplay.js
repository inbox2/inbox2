// Shared member-display helpers for the Team table and the per-member access
// page (kept out of the component files so fast refresh stays intact).
export const ROLE_LABEL = { owner: 'Owner', admin: 'Admin', member: 'Member' };
export const STATUS_LABEL = { active: 'Active', invited: 'Invited', disabled: 'Disabled' };

export const who = (m) => m.user?.display_name || m.user?.username || m.email_addresses?.[0] || 'Member';
