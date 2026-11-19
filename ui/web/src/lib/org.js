// Org-scope guard for API calls.
//
// In the desktop app, local channels (Gmail/Office365/IMAP) are fully offline and
// have no org. The router still builds routes from a null org slug, which React
// Router stringifies to the literal "null"/"undefined" — so `if (orgSlug)` passes
// and org-scoped fetches resolve to `/orgs/null/...` → 404 on every load. Gate any
// org-scoped API call on this instead of a bare truthiness check.
export function isRealOrgId(org) {
  return !!org && org !== 'null' && org !== 'undefined';
}
