// Resolve a URL workspace slug to its (org, domain).
//
// In the web client the path's first segment is either a DOMAIN slug or the ORG
// slug:
//   - a DOMAIN slug (`d.slug`) → { org, domain } — /:slug/mail/inbox is that
//     domain's MX pool.
//   - the ORG slug/id (`org.slug`/`org.id`) → { org, domain: null } — org-level:
//     /:slug/mail/inbox is the whole org MX pool (member-scoped), /:slug/mail is
//     the unified inbox.
//
// The org slug is `org.name.parameterize`; it equals the default domain's slug
// only when the org is named after that domain (the common single-domain case).
// When they coincide, the domain match wins (a specific-domain view) — check the
// domains first below. `domain === null` therefore means "org-level, all domains",
// NOT "unknown"; callers that need a concrete domain (e.g. the settings page)
// fall back to the org's default domain themselves.
export function resolveWorkspace(organizations, slug) {
  if (!slug) return { org: null, domain: null };
  for (const org of organizations || []) {
    const domain = (org.domains || []).find((d) => d.slug === slug);
    if (domain) return { org, domain };
    if (org.slug === slug || org.id === slug) return { org, domain: null };
  }
  return { org: null, domain: null };
}

// The org's default (oldest) domain — `org.domain` mirrors its name. Used where a
// concrete domain is needed but the URL carried only the org slug.
export function defaultDomainOf(org) {
  const domains = org?.domains || [];
  return domains.find((d) => d.name === org.domain) || domains[0] || null;
}
