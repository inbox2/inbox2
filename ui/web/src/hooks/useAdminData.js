import { useState, useEffect, useCallback } from 'react';
import api from '../lib/api';

/* Real data for the MX admin console (/console). Builds one enriched row per
 * connected domain from the user's organizations, plus an aggregate `stats`
 * roll-up across all domains from the admin overview endpoint (mail flow, spam,
 * classification coverage, backlog). Per-domain counts come from Spaces +
 * Members. A failed sub-fetch degrades to zeroes rather than blanking the page.
 *
 * org.status: pending_dns | verified | receiving_mail | error
 *   → normalized to 'active' (receiving/verified) vs 'pending' for the cards. */
function normStatus(s) {
  return s === 'receiving_mail' || s === 'verified' ? 'active' : 'pending';
}

// Canonical OrganizationSerializer payload → the local "domain" shape the admin
// console renders. Shared by the console (useAdminData) and the per-domain
// settings page so the field mapping (and `status` normalization) can't drift.
export function orgToDomain(org) {
  return {
    key: org.id,
    name: org.domain || org.slug,
    domain: org.domain || org.slug,
    // Editable display name shown in the workspace tab (org.name), distinct from
    // the domain. Falls back to the domain when unset.
    displayName: org.name || org.domain || org.slug,
    slug: org.slug,
    status: normStatus(org.status),
    rawStatus: org.status,
    // Billing lock (over a downgraded plan's domain limit) → "Locked" badge +
    // mail bounces until upgrade.
    locked: org.locked || false,
    iconUrl: org.icon_url || null,
    // 'upload' | 'favicon' | null — drives whether "Re-fetch" is offered.
    iconSource: org.icon_source || null,
    logoUrl: org.logo_url || null,
    // Latest per-record DNS check ({ mx, spf, dmarc, dkim } booleans), or null
    // until the domain has been checked — drives the health card's record dots.
    dnsChecks: org.dns_checks || null,
    // The org's other domains (all domains are equal — there is no primary flag).
    // The workspace card represents the org via its default domain (`org.domain`,
    // the oldest); every other domain renders as its own sibling card. The API
    // sends them all under `org.domains` (OrganizationSerializer).
    // Each: { key, name, status, rawStatus, locked }.
    extraDomains: (org.domains || [])
      .filter((d) => d.name !== org.domain)
      .map((d) => ({
        key: d.id,
        name: d.name,
        status: normStatus(d.status),
        rawStatus: d.status,
        locked: d.locked || false,
        dnsChecks: d.dns_checks || null,
      })),
  };
}

const EMPTY_STATS = {
  inbound7d: 0, outbound7d: 0, inboundDelta: null, outboundDelta: null,
  inboundSeries: [], outboundSeries: [],
  spamBlocked: 0, spamCaughtRate: null, coverage: null, unrouted: 0,
  spaceNames: [],
};

// Does a member see this domain's pool slice? All-domains members (owners/admins
// or explicitly all_domains) do; otherwise only if the domain is in their grants.
function memberSeesDomain(m, domainId) {
  return m.all_domains || (m.domains || []).some((d) => d.id === domainId);
}

// Fetch one org's members/spaces once, then a per-DOMAIN stats row for each of
// its domains (users = members with access, emails/unread = that domain's pool
// slice via ?domain=). Returns { orgOverview, spaceNames, rows } — orgOverview
// feeds the org-wide hero aggregate; rows are the per-domain cards.
async function enrich(org) {
  const domains = org.domains || [];
  const [spacesRes, membersRes, orgOvRes, ...domOvs] = await Promise.all([
    api.get(`/orgs/${org.id}/spaces`).catch(() => ({ spaces: [] })),
    api.getMembers(org.id).catch(() => ({ members: [] })),
    api.get(`/orgs/${org.id}/admin/overview`).catch(() => ({ overview: null })),
    ...domains.map((d) => api.get(`/orgs/${org.id}/admin/overview?domain=${d.id}`).catch(() => ({ overview: null }))),
  ]);
  const members = membersRes.members || [];
  const spaceNames = [...(spacesRes.spaces || [])]
    .sort((a, b) => (b.volume || 0) - (a.volume || 0))
    .map((x) => ({ id: x.id, name: x.name }));

  const rows = domains.map((d, i) => {
    const overview = domOvs[i]?.overview || null;
    const seers = members.filter((m) => memberSeesDomain(m, d.id));
    const isDefault = d.name === org.domain;
    return {
      key: d.id,          // unique per domain (card key)
      orgKey: org.id,
      domainKey: d.id,
      name: d.name,
      domain: d.name,
      isDefault,
      slug: org.slug,
      status: normStatus(d.status),
      rawStatus: d.status,
      locked: d.locked || false,
      // `slug` = the ORG slug (org-level ops: getOrg, per-domain settings page).
      // `domainSlug` = this domain's own URL slug (the /:domainSlug/mail/inbox tab).
      domainSlug: d.slug || org.slug,
      // Prefer the domain's own icon. Only the DEFAULT domain inherits the
      // org-level icon (it represents the org — same rule as the workspace tab
      // in useAccounts); sibling domains fall back to initials so one domain's
      // brand never bleeds onto the others.
      iconUrl: d.icon_url || (isDefault ? org.icon_url : null) || null,
      dnsChecks: d.dns_checks || null,
      // Per-domain figures — the whole point: each domain shows ITS slice.
      users: seers.length,
      members: seers.map((m) => ({
        name: m.user?.display_name || m.user?.username || m.email_addresses?.[0] || '?',
        email: m.user?.billing_email || m.email_addresses?.[0] || null,
      })),
      emails: overview?.pool?.volume ?? 0,
      unread: overview?.pool?.unread ?? 0,
      overview,
    };
  });
  return { orgOverview: orgOvRes.overview || null, spaceNames, rows };
}

function pct(cur, prev) {
  if (!prev) return null;
  return Math.round(((cur - prev) / prev) * 100);
}

// Org-wide hero aggregate — sums each org's org-level overview (not the per-domain
// rows, so null-domain threads still count).
function aggregate(results) {
  const ovs = results.map((r) => r.orgOverview).filter(Boolean);
  if (ovs.length === 0) return EMPTY_STATS;
  const sum = (f) => ovs.reduce((a, o) => a + (f(o) || 0), 0);
  const sumSeries = (key) => {
    const acc = Array(7).fill(0);
    ovs.forEach((o) => (o[key]?.series || []).forEach((v, i) => { acc[i] += v; }));
    return acc;
  };
  const inLast7 = sum((o) => o.inbound?.last7);
  const inPrev7 = sum((o) => o.inbound?.prev7);
  const outLast7 = sum((o) => o.outbound?.last7);
  const outPrev7 = sum((o) => o.outbound?.prev7);
  const classified = sum((o) => o.classification?.classified);
  const classifiable = sum((o) => o.classification?.classifiable);
  const scanned = sum((o) => o.spam?.scanned_7d);
  const blocked7 = sum((o) => o.spam?.blocked_7d);
  const inboundSeries = sumSeries('inbound');
  // Distinct real space names across all orgs (order preserved, busiest first)
  // for the hero's AI-filtering chips.
  const seen = new Set();
  const spaceNames = [];
  results.forEach((r) => (r.spaceNames || []).forEach((s) => {
    if (s.name && !seen.has(s.name)) { seen.add(s.name); spaceNames.push(s.name); }
  }));
  return {
    inbound7d: inLast7,
    outbound7d: outLast7,
    inboundDelta: pct(inLast7, inPrev7),
    outboundDelta: pct(outLast7, outPrev7),
    inboundSeries,
    outboundSeries: sumSeries('outbound'),
    spamBlocked: blocked7,
    spamCaughtRate: scanned ? blocked7 / scanned : null,
    coverage: classifiable ? classified / classifiable : null,
    unrouted: sum((o) => o.unrouted),
    spaceNames,
  };
}

export default function useAdminData(organizations) {
  const [domains, setDomains] = useState([]);
  const [stats, setStats] = useState(EMPTY_STATS);
  const [loading, setLoading] = useState((organizations || []).length > 0);

  const reload = useCallback(async (orgs) => {
    const results = (await Promise.all((orgs || []).map((o) => enrich(o).catch(() => null)))).filter(Boolean);
    const rows = results.flatMap((r) => r.rows);
    setDomains(rows);
    setStats(aggregate(results));
    setLoading(false);
    return rows;
  }, []);

  useEffect(() => {
    const orgs = organizations || [];
    if (orgs.length === 0) return undefined;
    let cancelled = false;
    (async () => {
      const results = (await Promise.all(orgs.map((o) => enrich(o).catch(() => null)))).filter(Boolean);
      if (!cancelled) {
        setDomains(results.flatMap((r) => r.rows));
        setStats(aggregate(results));
        setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [organizations]);

  // Re-fetch every org (e.g. after a downgrade locks domains) so badges refresh.
  const refresh = useCallback(() => reload(organizations), [reload, organizations]);

  // Optimistic local updates so the console reflects a remove / verify without a
  // full session refresh.
  const dropDomain = useCallback((key) => {
    setDomains((d) => d.filter((x) => x.key !== key));
  }, []);
  const markActive = useCallback((key) => {
    setDomains((d) => d.map((x) => (x.key === key ? { ...x, status: 'active' } : x)));
  }, []);
  const setIcon = useCallback((key, url, source) => {
    setDomains((d) => d.map((x) => (x.key === key ? { ...x, iconUrl: url, iconSource: source } : x)));
  }, []);
  const setLogo = useCallback((key, url) => {
    setDomains((d) => d.map((x) => (x.key === key ? { ...x, logoUrl: url } : x)));
  }, []);
  const setName = useCallback((key, name) => {
    setDomains((d) => d.map((x) => (x.key === key ? { ...x, displayName: name } : x)));
  }, []);

  return { domains, stats, loading, refresh, dropDomain, markActive, setIcon, setLogo, setName };
}
