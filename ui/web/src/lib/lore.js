// Lore — the open-workload view (docs/plans/lore.md). Pure, so the bucket,
// ranking and entity rules are unit-tested; useLore does the fetching.
//
// A Lore item IS a thread: open = still in the inbox with a Lore label,
// done = archived. The exception is a personal bucket on a shared MX domain:
// done there is the member's own (isMemberDone). Nothing here stores state of its own.
import { conversationPreview } from './conversationPreview';
import { fromName } from './spaceBoard';
import { titleCaseSlug } from './triage';

/** Where a thread sits in Lore, decided by its Jev triage label. */
export const LORE_BUCKET = {
  REPLY: 'reply',
  WORK: 'work',
  PAY: 'pay',
  MEET: 'meet',
  REVIEW: 'review',
  READ: 'read',
  WAITING: 'waiting',
  HANDLED: 'handled',
};

// Section order on the Today page, with the copy each section carries.
export const LORE_SECTIONS = [
  { bucket: LORE_BUCKET.PAY, title: 'To pay', rule: 'Invoices and reminders not paid automatically', tone: 'pay' },
  { bucket: LORE_BUCKET.REPLY, title: 'To reply', rule: 'A question is waiting on you', tone: 'reply' },
  { bucket: LORE_BUCKET.WORK, title: 'Work & requests', rule: 'Something you have to do or approve', tone: 'work' },
  { bucket: LORE_BUCKET.MEET, title: 'Meetings & opinions', rule: 'Someone wants your time', tone: 'meet' },
  { bucket: LORE_BUCKET.REVIEW, title: 'To review', rule: 'Data to look over, not act on', tone: 'review' },
  { bucket: LORE_BUCKET.READ, title: 'Read later', rule: 'Kept and summarised, not urgent', tone: 'read' },
  { bucket: LORE_BUCKET.WAITING, title: 'Waiting on others', rule: 'You asked; no answer yet', tone: 'wait' },
];

// Short tag text per bucket (table cells, mobile rows).
export const BUCKET_TAG = {
  [LORE_BUCKET.PAY]: 'Pay',
  [LORE_BUCKET.REPLY]: 'Reply',
  [LORE_BUCKET.WORK]: 'Work',
  [LORE_BUCKET.MEET]: 'Meet',
  [LORE_BUCKET.REVIEW]: 'Review',
  [LORE_BUCKET.READ]: 'Read',
  [LORE_BUCKET.WAITING]: 'Waiting',
  [LORE_BUCKET.HANDLED]: 'Handled',
};

// Built-in Jev label → bucket (docs/Triage.md). `resolved` has no bucket: it is
// done by definition. A custom label is work unless it maps here.
export const LABEL_BUCKET = {
  needs_answer: LORE_BUCKET.REPLY,
  needs_approval: LORE_BUCKET.WORK,
  action_required: LORE_BUCKET.WORK,
  payment_due: LORE_BUCKET.PAY,
  scheduling: LORE_BUCKET.MEET,
  to_review: LORE_BUCKET.REVIEW,
  read_later: LORE_BUCKET.READ,
  waiting_reply: LORE_BUCKET.WAITING,
  needs_answer_other: LORE_BUCKET.WAITING,
  fyi: LORE_BUCKET.HANDLED,
  receipt: LORE_BUCKET.HANDLED,
  notification: LORE_BUCKET.HANDLED,
};
const DONE_LABELS = new Set(['resolved']);

// Personal buckets (api TriageLabel::PERSONAL): on a shared domain a tick hides these
// for the member who ticked, and work items archive for the team. Gmail/IMAP mail has
// one owner, so it keeps done == archived.
export const PERSONAL_LABELS = new Set(['read_later', 'fyi', 'receipt', 'notification']);

/** Is this item's "done" per member (not an archive for the team)? */
export const isMemberDone = (item) => item.source === 'mx' && PERSONAL_LABELS.has(item.label);

/** "Handled for you" groups: what Lore suggests doing with each, in order.
 *  Suggest-only (decided 2026-10-20): nothing moves until the person presses. */
export const HANDLED_GROUPS = [
  { label: 'fyi', title: 'FYI threads', verb: 'Summarise and archive', button: 'Archive', action: 'archive' },
  { label: 'receipt', title: 'Receipts and confirmations', verb: 'File in the archive', button: 'File', action: 'archive' },
  { label: 'notification', title: 'Sign-in codes and system alerts', verb: 'Delete', button: 'Delete', action: 'trash' },
];

/** A Handled group's button: on shared-domain mail it only hides the threads for you. */
export const groupButton = (g) => (g.items.length && g.items.every(isMemberDone) ? 'Hide' : g.button);

/** The built-in labels Lore asks the API for (custom labels come along client-side). */
export const LORE_LABELS = Object.keys(LABEL_BUCKET);

// Entity kinds (api LoreEntity::KINDS) as a page shows them.
export const LORE_KIND_LABEL = { organization: 'Organization', person: 'Person', product: 'Product', project: 'Project' };

/** A label → its bucket, or null when it has none (resolved / untriaged). */
export function bucketFor(label) {
  if (!label || DONE_LABELS.has(label)) return null;
  return LABEL_BUCKET[label] || LORE_BUCKET.WORK;
}

// Buckets "Do first" is drawn from — the ones that need the person.
const ACTION_BUCKETS = new Set([LORE_BUCKET.PAY, LORE_BUCKET.REPLY, LORE_BUCKET.WORK, LORE_BUCKET.MEET]);
export const DO_FIRST_COUNT = 3;

// Mail providers whose domain names a person, not an organization.
export const FREEMAIL = new Set([
  'gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'msn.com', 'yahoo.com', 'ymail.com',
  'icloud.com', 'me.com', 'mac.com', 'aol.com', 'proton.me', 'protonmail.com', 'gmx.com', 'gmx.net', 'gmx.de',
  'mail.com', 'zoho.com', 'yandex.com', 'hey.com', 'fastmail.com',
]);

// Second-level public suffixes common in this mailbox (co.uk, com.pk, …): the
// org is one label further left. ponytail: a short list, not the full PSL — add
// the PSL when a wrong org grouping shows up.
const SECOND_LEVEL = new Set(['co', 'com', 'org', 'net', 'ac', 'gov', 'edu']);

/** "Maya <maya@mail.acme.co.uk>" → "maya@mail.acme.co.uk" (lower case). */
export function addressOf(from) {
  const m = String(from || '').match(/<([^>]+)>/);
  return (m ? m[1] : String(from || '')).trim().toLowerCase();
}

/** The organization's registrable domain for an address, or null for freemail. */
export function orgDomain(from) {
  const addr = addressOf(from);
  const host = addr.includes('@') ? addr.split('@').pop() : '';
  if (!host || !host.includes('.')) return null;
  const parts = host.split('.');
  const keep = parts.length > 2 && SECOND_LEVEL.has(parts[parts.length - 2]) ? 3 : 2;
  const domain = parts.slice(-keep).join('.');
  return FREEMAIL.has(domain) ? null : domain;
}

/** "acme.co.uk" → "Acme" — a display name until the brand lookup names it. */
export function domainLabel(domain) {
  const first = String(domain || '').split('.')[0];
  return first ? first[0].toUpperCase() + first.slice(1) : '';
}

const ts = (iso) => Date.parse(iso) || 0;
const score = (p) => (p == null || p === '' || Number.isNaN(Number(p)) ? -1 : Number(p));

/**
 * An API (MX) conversation or a local SQLite row → a Lore item.
 *   source: 'mx' (orgId routes actions) | 'local' (accountKey routes them)
 * Returns null for a thread Lore doesn't hold (no label, or resolved).
 */
export function toItem(row, { source, orgId = null, labels = [] } = {}) {
  const label = row.triage_label || null;
  const bucket = bucketFor(label);
  if (!bucket) return null;
  const id = row.id || row.key;
  const custom = !Object.hasOwn(LABEL_BUCKET, label);
  return {
    id,
    uid: `${source}:${id}`,
    source,
    orgId: source === 'mx' ? orgId : null,
    accountKey: source === 'local' ? row.account_key : null,
    provider: source === 'local' ? (row.provider_type || null) : 'inbox2',
    // MX: the domain the mail came in on (its tab's unread badge is keyed by that domain).
    mailDomain: source === 'mx' ? (addressOf(row.to_address).split('@')[1] || null) : null,
    subject: row.subject || '(no subject)',
    // What to call it in Lore: the AI-written to-do title when the summary pass
    // wrote one, else the subject without its Re:/Fwd:/reminder prefixes.
    title: row.next_action_title || cleanSubject(row.subject) || row.subject || '(no subject)',
    reminder: REMINDER.test(String(row.subject || '').replace(REPLY_PREFIX, '')),
    detail: conversationPreview(row),
    from: fromName(row.from_address),
    address: addressOf(row.from_address),
    domain: orgDomain(row.from_address),
    label,
    labelName: custom ? (labels.find((l) => l.slug === label)?.name || titleCaseSlug(label)) : null,
    bucket,
    priority: score(row.triage_priority),
    at: ts(row.updated_at || row.created_at),
    unread: row.read === false || row.read === 0,
    status: row.status || null,
    loreDone: !!row.lore_done,
    // Next-action fields, extracted from the mail when the label is set (docs/Triage.md).
    dueAt: dueAtOf(row.next_action_due_on),
    amount: formatAmount(row.next_action_amount_cents, row.next_action_currency),
    amountCents: row.next_action_amount_cents == null || row.next_action_amount_cents === '' ? null : Number(row.next_action_amount_cents),
    currency: row.next_action_currency || null,
  };
}

/**
 * A local-WhatsApp ask (a `wa_lore` row, ui/desktop/src-tauri/src/whatsapp_lore.rs)
 * → a Lore item. Same shape as a thread's, plus where to open the chat
 * (`chatId`, `askId`); no address, so it names no person or organization here
 * (the ontology miner records WhatsApp people itself).
 */
export function waItem(row, { labels = [] } = {}) {
  const item = toItem({
    key: `wa:${row.chat_id}`,
    subject: row.chat_name,
    next_action_title: row.title,
    snippet: row.summary,
    from_address: row.is_group ? (row.sender || row.chat_name) : row.chat_name,
    triage_label: row.label,
    triage_priority: row.priority,
    updated_at: row.ask_at,
    read: true,
    status: row.status,
    next_action_due_on: row.next_action_due_on,
    next_action_amount_cents: row.next_action_amount_cents,
    next_action_currency: row.next_action_currency,
  }, { source: WA_SOURCE, labels });
  if (!item) return null;
  return {
    ...item,
    provider: WA_SOURCE,
    address: null,
    domain: null,
    chatId: row.chat_id,
    askId: row.ask_from_id,
    avatar: row.avatar || null,
    isGroup: !!row.is_group,
    // A group's ask names its group: that page is where tracking is switched on.
    group: row.is_group ? { chatId: row.chat_id, name: row.chat_name } : null,
  };
}

/** Lore items read from WhatsApp Desktop on this Mac. */
export const WA_SOURCE = 'whatsapp';

// A tracked group's to-do takes a label by whose it is: the owner's own is
// something to do (Today), anyone else's is something you wait on.
export const WA_TODO_LABEL = { MINE: 'action_required', THEIRS: 'waiting_reply' };
// wa_lore.done_reason for an owner-only ask a tracked group's list took over
// (whatsapp_groups.rs DONE_TRACKED): closed, but not done by anyone.
export const WA_DONE_TRACKED = 'tracked';

/**
 * A tracked WhatsApp group's to-do (a `wa_group_todos` row joined with its
 * `wa_groups` row, ui/desktop/src-tauri/src/whatsapp_groups.rs) → a Lore item.
 * Opens the chat at the message that raised it; `todoId` routes the tick.
 */
export function waTodoItem(row) {
  const mine = !!row.mine;
  const item = toItem({
    key: `wa-todo:${row.id}`,
    subject: row.chat_name,
    next_action_title: row.title,
    snippet: row.summary,
    from_address: mine ? 'You' : (row.owner || row.chat_name),
    triage_label: mine ? WA_TODO_LABEL.MINE : WA_TODO_LABEL.THEIRS,
    // A done one dates from when it was done ("Recently done" sorts on it).
    updated_at: row.done_at || row.at,
    read: true,
    status: row.status,
  }, { source: WA_SOURCE });
  if (!item) return null;
  return {
    ...item,
    provider: WA_SOURCE,
    address: null,
    domain: null,
    chatId: row.chat_id,
    askId: row.from_id,
    todoId: row.id,
    mine,
    avatar: row.avatar || null,
    isGroup: true,
    group: { chatId: row.chat_id, name: row.chat_name },
  };
}

/** WhatsApp groups with open items (tracked groups' to-dos, other groups' asks): [{ chatId, name, count }]. */
export function waGroupsFrom(items) {
  const groups = new Map();
  for (const i of items) {
    if (!i.group) continue;
    const g = groups.get(i.group.chatId) || { ...i.group, count: 0 };
    g.count += 1;
    groups.set(i.group.chatId, g);
  }
  return [...groups.values()].sort((a, b) => (b.count - a.count) || a.name.localeCompare(b.name));
}

// Reply/forward markers in the languages this mailbox sees (en, nl, de, fr).
const REPLY_PREFIX = /^(?:\s*(?:re|fw|fwd|aw|wg|antw|tr)\s*(?:\[\d+\])?\s*:\s*)+/i;
// "Herinnering:", "Reminder -", "2e herinnering:" — a nudge about an earlier mail.
const REMINDER = /^\s*(?:\d+(?:e|nd|rd|th)?\s+)?(?:herinnering|reminder|aanmaning|betalingsherinnering|erinnerung|rappel)\b\s*[:\-–]?\s*/i;
const NOISE_PREFIX = /^\s*(?:\[?action required\]?|actie vereist)\s*[:\-–]\s*/i;

/** "RE: Herinnering: Privium factuur" → "Privium factuur". */
export function cleanSubject(subject) {
  let t = String(subject || '').replace(REPLY_PREFIX, '');
  t = t.replace(REMINDER, '').replace(NOISE_PREFIX, '').replace(/\s+/g, ' ').trim();
  return t ? t[0].toUpperCase() + t.slice(1) : '';
}

/** "2026-10-24" → the end of that local day (ms), or null. */
export function dueAtOf(date) {
  const m = String(date || '').match(/^(\d{4})-(\d{2})-(\d{2})/);
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 23, 59, 59).getTime() : null;
}

/** 38600, "EUR" → "€386.00" in the viewer's locale; null without both parts. */
export function formatAmount(cents, currency) {
  if (cents == null || cents === '' || !currency) return null;
  try {
    return new Intl.NumberFormat(undefined, { style: 'currency', currency }).format(Number(cents) / 100);
  } catch {
    return `${currency} ${(Number(cents) / 100).toFixed(2)}`;
  }
}

const DAY = 86400000;

/** A due date as a short phrase: overdue / today / tomorrow / in 3 days / Oct 24. */
export function dueLabel(dueAt, now = Date.now()) {
  if (!dueAt) return '';
  const days = Math.floor((dueAt - now) / DAY);
  if (dueAt < now) return 'overdue';
  if (days === 0) return 'today';
  if (days === 1) return 'tomorrow';
  if (days < 7) return `in ${days} days`;
  return new Date(dueAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

/** Is the due date close enough to flag (overdue or within 3 days)? */
export const dueSoon = (dueAt, now = Date.now()) => !!dueAt && dueAt - now < 3 * DAY;

/**
 * Ranking score: Jev priority (0–4, -1 untriaged) raised by a near deadline —
 * overdue +1.5, within 3 days +1, within a week +0.5. ponytail: fixed bumps,
 * tune with real data.
 */
export function urgency(item, now = Date.now()) {
  if (!item.dueAt) return item.priority;
  const left = item.dueAt - now;
  const bump = left < 0 ? 1.5 : left < 3 * DAY ? 1 : left < 7 * DAY ? 0.5 : 0;
  return Math.max(item.priority, 0) + bump;
}

/** Most urgent first (priority + deadline), then newest. */
export function compareItems(a, b, now = Date.now()) {
  return (urgency(b, now) - urgency(a, now)) || (b.at - a.at);
}

// Reference numbers in a subject or summary: invoice / dossier / ticket ids (4+
// digits) — years aren't references ("Factuur oktober 2026" vs "november 2026").
const YEAR = /^(19|20)\d\d$/;
const refsOf = (i) => new Set((`${i.subject} ${i.detail || ''}`.match(/\d{4,}/g) || []).filter((n) => !YEAR.test(n)));
// Subject words that carry the topic ("Uw Privium Members Club factuur" → privium, members, club, factuur).
const FILLER = new Set(['uw', 'your', 'the', 'de', 'het', 'een', 'van', 'voor', 'for', 'and', 'en', 'from', 'from']);
const topicWords = (i) => new Set(cleanSubject(i.subject).toLowerCase().split(/[^\p{L}\p{N}]+/u)
  .filter((w) => w.length > 2 && !FILLER.has(w) && !YEAR.test(w)));
/** Share of the smaller subject's topic words the other one also has. */
function overlap(a, b) {
  const wa = topicWords(a);
  const wb = topicWords(b);
  const small = wa.size <= wb.size ? wa : wb;
  const big = small === wa ? wb : wa;
  if (!small.size) return 0;
  let n = 0;
  for (const w of small) if (big.has(w)) n += 1;
  return n / small.size;
}
const REMINDER_OVERLAP = 0.6;

/** Are two threads from one counterpart about the same request? A shared
 *  reference number, or — for a reminder — most of the other's subject words
 *  ("Herinnering: Privium factuur" ~ "Uw Privium factuur"). The same subject
 *  alone isn't enough: two "Invoice" mails are usually two invoices. */
export function related(a, b) {
  const refs = refsOf(a);
  for (const r of refsOf(b)) if (refs.has(r)) return true;
  return (a.reminder || b.reminder) && overlap(a, b) >= REMINDER_OVERLAP;
}

/**
 * Threads about the same request, as one Lore entry: same bucket, same
 * counterpart (organization domain, else sender address) AND related (an invoice
 * and its reminder, a reply on the same dossier). Separate invoices from one
 * company stay separate. `sorted` is most-urgent first, so each group's lead
 * (and the group order) follows urgency.
 *   → [{ uid, bucket, lead, items, dueAt (earliest), total (the amount when every
 *        priced thread names the same one — a reminder repeats the debt, it doesn't add to it) }]
 */
export function groupItems(sorted) {
  const byKey = new Map(); // bucket|counterpart → groups
  const out = [];
  for (const i of sorted) {
    const key = `${i.bucket}|${i.domain || i.address || i.uid}`;
    const candidates = byKey.get(key) || [];
    let g = candidates.find((c) => c.items.some((m) => related(m, i)));
    if (!g) {
      g = { uid: `g:${i.uid}`, bucket: i.bucket, lead: i, items: [] };
      byKey.set(key, [...candidates, g]);
      out.push(g);
    }
    g.items.push(i);
  }
  for (const g of out) {
    const dues = g.items.map((i) => i.dueAt).filter(Boolean);
    g.dueAt = dues.length ? Math.min(...dues) : null;
    const priced = g.items.filter((i) => i.amountCents != null);
    // Different amounts can't be told apart as one debt or several: no total,
    // the lead shows its own and the unfolded rows show theirs.
    const same = priced.length > 1 && priced.every((i) => i.currency === priced[0].currency && i.amountCents === priced[0].amountCents);
    g.total = same ? formatAmount(priced[0].amountCents, priced[0].currency) : null;
  }
  return out;
}

/**
 * Build the Today page from open items (done ones already filtered out).
 * Returns { first, sections, handled, open }:
 *   first    — the top action groups, most urgent first (groupItems shape)
 *   sections — LORE_SECTIONS with their groups (first ones not repeated) and
 *              `items`, the same threads flat (tables, counts)
 *   handled  — HANDLED_GROUPS with their items (suggestions, not yet acted on)
 *   open     — the thread count that needs the person (everything but handled)
 */
export function buildToday(items, now = Date.now()) {
  const sorted = [...items].sort((a, b) => compareItems(a, b, now));
  const groups = groupItems(sorted.filter((i) => i.bucket !== LORE_BUCKET.HANDLED));
  const first = groups.filter((g) => ACTION_BUCKETS.has(g.bucket)).slice(0, DO_FIRST_COUNT);
  const firstIds = new Set(first.map((g) => g.uid));
  const sections = LORE_SECTIONS.map((s) => {
    const mine = groups.filter((g) => g.bucket === s.bucket && !firstIds.has(g.uid));
    return { ...s, groups: mine, items: mine.flatMap((g) => g.items) };
  });
  const handled = HANDLED_GROUPS.map((g) => ({
    ...g,
    items: sorted.filter((i) => i.bucket === LORE_BUCKET.HANDLED && i.label === g.label),
  }));
  const open = sorted.filter((i) => i.bucket !== LORE_BUCKET.HANDLED).length;
  return { first, sections, handled, open };
}

/**
 * Organizations and people behind the items — the deterministic half of the
 * ontology (docs/plans/lore.md §4): an org per registrable sender domain, a
 * person per sender address. Most items first.
 */
export function entitiesFrom(items) {
  const orgs = new Map();
  const people = new Map();
  for (const i of items) {
    if (i.domain) {
      const o = orgs.get(i.domain) || { domain: i.domain, name: domainLabel(i.domain), count: 0, people: new Set() };
      o.count += 1;
      if (i.address) o.people.add(i.address);
      orgs.set(i.domain, o);
    }
    if (i.address) {
      const p = people.get(i.address) || { address: i.address, name: i.from || i.address, domain: i.domain, count: 0 };
      p.count += 1;
      people.set(i.address, p);
    }
  }
  const byCount = (a, b) => (b.count - a.count) || a.name.localeCompare(b.name);
  return {
    orgs: [...orgs.values()].map((o) => ({ ...o, people: o.people.size })).sort(byCount),
    people: [...people.values()].sort(byCount),
    groups: waGroupsFrom(items),
  };
}

/** Case-insensitive search over subject, detail, sender and organization. */
export function searchItems(items, query) {
  const q = String(query || '').trim().toLowerCase();
  if (!q) return items;
  return items.filter((i) => [i.title, i.subject, i.detail, i.from, i.address, i.domain, i.labelName]
    .some((v) => v && v.toLowerCase().includes(q)));
}

/** "3 days ago" style age for a Lore row (waiting-on lists read better this way).
 * Calendar days in local time: on the 10th a message from the 7th is 3 days old. */
export function ageLabel(at, now = Date.now()) {
  if (!at) return '';
  const midnight = (t) => new Date(t).setHours(0, 0, 0, 0);
  const days = Math.round((midnight(now) - midnight(at)) / 86400000);
  if (days <= 0) return 'today';
  if (days === 1) return 'yesterday';
  if (days < 7) return `${days} days`;
  const weeks = Math.floor(days / 7);
  return weeks === 1 ? '1 week' : `${weeks} weeks`;
}

/** How old a to-do is, 0 (this week's first days) … 4 (two months+): the left bar fades with it. */
export function ageStep(at, now = Date.now()) {
  if (!at) return 4;
  const days = (now - at) / 86400000;
  return days < 2 ? 0 : days < 7 ? 1 : days < 28 ? 2 : days < 56 ? 3 : 4;
}

/** Initials for an entity with no logo: "Ziggo" → "Z", "Ali Khan" → "AK". */
export function initials(name) {
  const words = String(name || '').trim().split(/\s+/).filter(Boolean);
  if (!words.length) return '?';
  return (words.length > 1 ? words[0][0] + words[1][0] : words[0][0]).toUpperCase();
}
