/* ⚠️ VISUAL-PROTOTYPE DATA ONLY — not production.
 * Hand-authored sample so we can iterate on the SpaceDashboard look before the
 * MX triage / routing backend exists. When wired up this is replaced by an API
 * hook (e.g. useSpaceStats(domain)). Do not import into shipped, data-driven
 * paths. Models one SMB domain: acme.com. */

function member(id, name, open) {
  return { id, name, email: `${id}@acme.com`, open };
}

export const MOCK_SPACES = [
  {
    id: 'support',
    name: 'Support',
    openness: 'org', // open to everyone in the domain
    volume: 2140,
    unread: 34,
    unassigned: 22,
    members: [
      member('maya', 'Maya Chen', 41),
      member('devin', 'Devin Park', 33),
      member('lola', 'Lola Ferreira', 19),
      member('sam', 'Sam Whitfield', 13),
    ],
  },
  {
    id: 'sales',
    name: 'Sales',
    openness: 'assigned',
    volume: 1320,
    unread: 18,
    unassigned: 9,
    members: [
      member('tomas', 'Tomas Vidal', 28),
      member('priya', 'Priya Nair', 21),
      member('jordan', 'Jordan Blake', 16),
    ],
  },
  {
    id: 'marketing',
    name: 'Marketing',
    openness: 'org',
    volume: 890,
    unread: 12,
    unassigned: 14,
    members: [
      member('aiko', 'Aiko Tanaka', 17),
      member('ben', 'Ben Okafor', 11),
    ],
  },
  {
    id: 'finance',
    name: 'Finance',
    openness: 'assigned',
    volume: 560,
    unread: 7,
    unassigned: 3,
    members: [
      member('rosa', 'Rosa Klein', 18),
      member('ed', 'Ed Mortimer', 10),
    ],
  },
  {
    id: 'triage',
    name: 'Triage',
    openness: 'org',
    volume: 300,
    unread: 56,
    unassigned: 56, // nothing routed yet — the holding pen
    members: [],
  },
];

// Per-space value for a chosen metric. Members are always sized by open items.
export function spaceMetric(q, metric) {
  if (metric === 'volume') return q.volume;
  if (metric === 'unread') return q.unread;
  // 'open': API spaces carry a computed top-level count; mock spaces derive it
  // from per-member open items plus the unassigned holding pile.
  if (typeof q.open === 'number') return q.open;
  return q.members.reduce((s, m) => s + (m.open || 0), 0) + q.unassigned;
}

// ── Admin-side (light dashboard) sample domains ──
export const MOCK_DOMAINS = [
  {
    name: 'acme.com',
    status: 'active',
    users: 14,
    emails: 5210,
    unread: 127,
    storageGb: 8.4,
    storageCapGb: 25,
    actions: [
      { kind: 'ok', text: 'DNS verified · MX, SPF, DKIM' },
      { kind: 'warn', text: '3 invites pending' },
    ],
  },
  {
    name: 'northwind.co',
    status: 'active',
    users: 7,
    emails: 2980,
    unread: 54,
    storageGb: 3.1,
    storageCapGb: 25,
    actions: [{ kind: 'ok', text: 'All systems go' }],
  },
  {
    name: 'acme.io',
    status: 'pending',
    users: 2,
    emails: 0,
    unread: 0,
    storageGb: 0,
    storageCapGb: 25,
    actions: [{ kind: 'warn', text: 'Add MX record to verify domain' }],
  },
];

// ── Per-space message lists (embedded in treemap cells) ──
// Fictional senders/subjects only — keep the SpaceDashboard prototype free of
// any real mailbox content. Names mirror the made-up acme.com roster above.
const SENDERS = [
  'Maya Chen', 'Devin Park', 'Lola Ferreira', 'Sam Whitfield', 'Tomas Vidal', 'Priya Nair',
  'Lena Hoffmann', 'Marcus Bell', 'Aiko Tanaka', 'Ben Okafor', 'Rosa Klein', 'Jordan Blake',
];
const SUBJECTS = [
  'RE: Master data ready for testing', 'RE: Petty cash reconciliation', 'RE: Role definitions & access',
  'RE: Revenue recognition — Oct', 'FW: Actual vs. budget review', 'RE: UAT database access',
  'New leads and prospects', 'Spreadsheet shared with you', 'Fwd: Property listing update',
  'RE: VAT group filing', 'Folder shared with you', 'Project requirements — draft',
  'Re: Procurement & CRM rollout', 'ERP walkthrough scheduled', 'Invoice #4821 overdue',
  'Q3 campaign assets ready', 'Payout of €12,480 on the way', 'Contract redlines from legal',
  'Ticket #3391 reopened', 'Newsletter — 38% open rate',
];
const DATES = ['Nov 14', 'Nov 14', 'Nov 10', 'Oct 16', 'Oct 15', 'Oct 7', 'Oct 3', 'Sep 30', 'Sep 26', 'Jul 30', 'Jul 24', 'Jun 18', 'Jun 12', 'May 28', 'May 9', 'Apr 30'];
const PROVIDERS = ['gmail', 'microsoft', 'inbox2', 'whatsapp', 'imap'];
const PREVIEWS = [
  'Just chasing this up before month-end so we can close the books on time.',
  'Please find the latest figures attached for your review and sign-off.',
  'Let me know if next Tuesday works for the walkthrough with the team.',
  'The updated records are ready — I flagged two items that need a look.',
  'Expected to arrive within two business days; I\'ll confirm once it\'s sent.',
  'Two clauses still need sign-off from legal before we can proceed.',
  'Customer replied that the issue is still occurring on their end.',
  'Best results this quarter — the full breakdown is inside the deck.',
  'Thanks for the quick turnaround, this unblocks the rest of the rollout.',
];

function hashStr(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i += 1) { h ^= s.charCodeAt(i); h = (h * 16777619) >>> 0; }
  return h;
}
function lcg(seed) { return (seed * 1103515245 + 12345) & 0x7fffffff; }

function genMessages(id, n) {
  let seed = hashStr(id);
  const out = [];
  for (let i = 0; i < n; i += 1) {
    seed = lcg(seed);
    const from = SENDERS[(seed >> 3) % SENDERS.length];
    seed = lcg(seed);
    const subject = SUBJECTS[(seed >> 4) % SUBJECTS.length];
    seed = lcg(seed);
    const provider = PROVIDERS[(seed >> 6) % PROVIDERS.length];
    seed = lcg(seed);
    const preview = PREVIEWS[(seed >> 2) % PREVIEWS.length];
    out.push({ id: `${id}-${i}`, from, subject, preview, provider, date: DATES[i % DATES.length], attachment: ((seed >> 5) & 3) === 0, unread: i < 2 });
  }
  return out;
}

export const SPACE_MESSAGES = Object.fromEntries(MOCK_SPACES.map((s) => [s.id, genMessages(s.id, 18)]));
