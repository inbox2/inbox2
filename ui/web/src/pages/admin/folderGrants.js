/* Pure logic for the member page's "Folders <name> gets" table (address folders).
 * Read = domain pool access, or a `to equals <address>` grant_access rule for a
 * scoped member; Reply as = membership send_as_addresses. */

const lc = (s) => (s || '').trim().toLowerCase();
const hostOf = (addr) => lc(addr).split('@')[1] || '';

// The rule that gives this member Read on one address: one condition,
// `to equals <address>`, with a grant_access action for the member.
export function readRulesFor(rules, memberId, address) {
  const want = lc(address);
  return (rules || []).filter((r) => {
    const conds = r.conditions || [];
    return conds.length === 1 && conds[0].field === 'to' && conds[0].operator === 'equals' && lc(conds[0].value) === want
      && (r.actions || []).some((a) => a.type === 'grant_access' && a.value === memberId);
  });
}

// send_as_addresses with `address` ticked on or off (case-insensitive, no dupes).
export function withSendAs(list, address, on) {
  const rest = (list || []).filter((a) => lc(a) !== lc(address));
  return on ? [...rest, lc(address)] : rest;
}

// The domains a member works on (mirrors Membership#home_domain_ids): pool
// grants, plus domains where they hold a mailbox or a send-as address.
export function workDomains(member, domains) {
  if (member.all_domains) return domains;
  const ids = new Set((member.domains || []).map((d) => d.id));
  const hosts = new Set([
    ...(member.mailboxes || []).map((m) => hostOf(m.email_address)),
    ...(member.send_as_addresses || []).map(hostOf),
  ]);
  return domains.filter((d) => ids.has(d.id) || hosts.has(lc(d.name)));
}

/* Rows for the table. `sharedByDomain` = { [domainId]: [{ address, ... }] }.
 * Each row: { kind: 'own'|'shared'|'extra', address, read, readLocked, replyAs, rules }.
 *   readLocked = 'admin' (owners/admins/all-domains) | 'domain' (pool access) | null. */
export function folderRows({ member, domains, sharedByDomain, rules }) {
  const isAdmin = member.role === 'owner' || member.role === 'admin';
  const everything = isAdmin || member.all_domains;
  const pool = new Set((member.domains || []).map((d) => d.id));
  const sendAs = new Set((member.send_as_addresses || []).map(lc));
  const own = (member.mailboxes || []).map((m) => lc(m.email_address)).filter(Boolean);

  const rows = own.map((address) => ({ kind: 'own', address }));
  const listed = new Set(own);
  for (const d of workDomains(member, domains)) {
    for (const s of sharedByDomain[d.id] || []) {
      const address = lc(s.address);
      if (listed.has(address)) continue;
      listed.add(address);
      const readLocked = everything ? 'admin' : pool.has(d.id) ? 'domain' : null;
      const matched = readLocked ? [] : readRulesFor(rules, member.id, address);
      rows.push({
        kind: 'shared', address, displayName: s.display_name || null,
        read: !!readLocked || matched.length > 0, readLocked, rules: matched,
        replyAs: sendAs.has(address),
      });
    }
  }
  // Send-as grants that are not on any shared list stay visible so they can be removed.
  for (const address of sendAs) {
    if (!listed.has(address)) rows.push({ kind: 'extra', address, replyAs: true });
  }
  return rows;
}
