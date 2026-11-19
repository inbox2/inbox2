// Demo mode — fake people and mail for screenshots and live demos.
//
// Nothing is rewritten on disk: the real rows stay in SQLite and on the server.
// Demo mode rewrites the *reads*. Every address, name, subject, snippet and
// body on its way to the UI is swapped for a fictional stand-in, chosen by
// hashing the real value — so one real address is always the same fake person,
// on every screen, and threads still hang together. Row counts, timestamps,
// read state, attachments, Spaces and triage labels are untouched, so the app
// looks exactly as busy as it really is.
//
// Three read chokepoints carry it: lib/db.js (local channels), lib/api.js (MX)
// and useAccounts (the channel tabs). Anything that slips through gets one more
// scrub() call at its own source — not a fourth mechanism.
//
// The flag lives in sessionStorage: it survives the reload that applies it and
// dies with the window, so nobody wonders the next morning where their mail went.
//
// While it is on, NOTHING LEAVES THE MACHINE: sending, provider write-backs
// (archive/read/priority/RSVP/calendar) and every MX write are refused at their
// boundaries (lib/providers, lib/api, lib/localFirstApi). Local SQLite writes still happen, so clicking
// around a demo behaves normally; the next real sync reconciles them, exactly as
// it would after any failed write-back.

import THREADS, { LORE_THREADS } from './demoCorpus';

const FLAG = 'inbox2:demo-mode';
const SALT_KEY = 'inbox2:demo-salt';

export function isDemoMode() {
  try {
    return sessionStorage.getItem(FLAG) === '1';
  } catch {
    return false; // private mode / blocked storage — demo mode is a nicety
  }
}

/** Flip demo mode and reload: every hook refetches through the scrubbed reads. */
export function toggleDemoMode() {
  const next = !isDemoMode();
  try {
    if (next) {
      sessionStorage.setItem(FLAG, '1');
      // A fresh salt per demo session (see saltedHash).
      sessionStorage.setItem(SALT_KEY, Math.random().toString(36).slice(2) + Date.now().toString(36));
    } else {
      sessionStorage.removeItem(FLAG);
      sessionStorage.removeItem(SALT_KEY);
    }
  } catch { /* can't persist → can't toggle; leave the app as it is */ }
  window.location.reload();
}

/** Shown instead of a message's raw MIME source while demo mode is on. */
export const DEMO_HIDDEN_SOURCE = 'Raw source is hidden while demo data is on.\n';

// ── The cast ──
// Generated from name parts rather than written out: 24 × 18 = 432 people, so
// unrelated contacts rarely collide onto the same stand-in (a 16-person cast put
// two different senders in one list under one name several times a screen).
// Invented companies, so a screenshot can't be mistaken for a real thread.
const FIRST_NAMES = [
  'Sarah', 'Tomas', 'Marieke', 'Jasper', 'Aisha', 'Daniel', 'Elena', 'Sanne',
  'Ravi', 'Lucia', 'Ben', 'Nadia', 'Pieter', 'Yuki', 'Clara', 'Omar',
  'Hannah', 'Mateo', 'Ingrid', 'Dexter', 'Priya', 'Lars', 'Amara', 'Felix',
];
const LAST_NAMES = [
  'Chen', 'Kok', 'de Groot', 'Vos', 'Rahman', 'Okafor', 'Marchetti', 'Peters',
  'Menon', 'Ferreira', 'Whitaker', 'Haddad', 'Bakker', 'Tanaka', 'Lindqvist', 'Aziz',
  'Novak', 'Ellery',
];

const COMPANIES = [
  'northwind.io', 'brightfold.co', 'nordkap.io', 'helixpay.com', 'orbitlabs.io',
  'veldhuis-legal.nl', 'kestreldata.com', 'atlasfreight.com', 'lumenworks.com', 'stratos.eu',
];
// Same order as COMPANIES: a workspace called "Northwind" keeps the domain
// northwind.io, so the tab and the addresses under it tell one story.
const COMPANY_NAMES = [
  'Northwind', 'Brightfold', 'Nordkap', 'Helixpay', 'Orbit Labs',
  'Veldhuis Legal', 'Kestrel Data', 'Atlas Freight', 'Lumenworks', 'Stratos',
];

const slug = (name) => name.toLowerCase().replace(/[^a-z]+/g, '');

// Subjects and bodies come in pairs (lib/demoCorpus.js) and are picked by ONE
// hash, so the subject, the list preview and the open thread all agree.
// The list preview is the body's first sentence — what a real snippet is.
const snippetOf = (t) => (t.body.split(/(?<=[.?!])\s/)[0] || t.body).trim();
// A few lines, for ai_summary_medium: the opening paragraph.
const paragraphOf = (t) => t.body.split('\n\n')[0];

// Lore's threads by triage label: a labelled row becomes one of these, so a "To
// pay" row is an invoice with an amount and a to-do title (lib/demoCorpus.js).
const LORE_BY_LABEL = LORE_THREADS.reduce((m, t) => ({ ...m, [t.label]: [...(m[t.label] || []), t] }), {});
// The thread a labelled row became, by its bare subject — so the messages of that
// thread (which carry no label) open as the same stand-in.
const LORE_PICKED = new Map();

// Mined Lore facts and entities (docs/Ontology.md): invented stand-ins.
const FAKE_PROJECTS = ['Platform migration', 'Q4 launch', 'Partner programme', 'Data warehouse', 'Mobile redesign', 'Pricing review'];
const FAKE_FACT_VALUES = ['Finance', 'Operations', 'Head of Sales', 'Procurement', 'Customer success', 'Engineering lead', 'Account manager'];
const ENTITY_KINDS = new Set(['organization', 'person', 'product', 'project']);
// Demo amounts for a labelled row whose thread names none: seeded, plausible.
const DEMO_AMOUNTS = [4900, 14900, 38600, 129000, 248000];

const PEOPLE = FIRST_NAMES.flatMap((first) =>
  LAST_NAMES.map((last, j) => ({
    name: `${first} ${last}`,
    // The company follows the surname, so colleagues keep sharing a domain.
    email: `${slug(first)}.${slug(last)}@${COMPANIES[j % COMPANIES.length]}`,
  }))
);

const PLACES = [
  'https://meet.google.com/qvx-mfad-rjp',
  'Meeting room Kubus — 4th floor',
  'https://teams.microsoft.com/l/meetup-join/19%3ademo',
  'Café Binnenhof, Rotterdam',
  'Room 2.14 (Atlas building)',
];

// Attachment names ride along in the list payload and the conversation row, so
// a real filename is as much of a leak as a real subject. Extension preserved —
// the file-type icon has to keep matching.
const FILE_STEMS = [
  'Q3-forecast', 'renewal-quote', 'contract-redlines', 'invoice-4821',
  'security-questionnaire', 'board-pack', 'shipping-manifest', 'meeting-notes',
  'budget-Q4', 'onboarding-plan',
];

// NOTE: there is deliberately no "is this value already fake?" check anywhere
// below. An earlier version exempted anything matching the generated cast so
// scrub() could run twice over one value — but that exempts REAL data that
// happens to collide with it, and "Sarah Chen" is a name real people have: hers
// would have gone straight through to the screenshot. Every value is scrubbed
// unconditionally, and instead each source scrubs exactly ONCE (lib/db.js,
// lib/api.js, lib/providers, sync-manager, the two account loads). A double
// scrub is now merely cosmetic — a second stand-in — never a leak.
// (Reserved .invalid domains would also close the collision, at the cost of
// every address in a screenshot reading as obviously fake. Scrubbing everything
// costs nothing and keeps the mail plausible.)

// FNV-1a over salt + value. Stable for the whole demo session, so one address
// is one stand-in on every screen — but the salt is random per session, so a
// published screenshot can't be walked backwards: without it, anyone holding a
// guessed address could hash it and check whether "their" stand-in appears,
// which turns a screenshot into a membership oracle for the mailbox.
function hash(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i += 1) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

let salt = null;
function demoSalt() {
  if (salt !== null) return salt;
  try {
    salt = sessionStorage.getItem(SALT_KEY) || '';
  } catch {
    salt = ''; // no storage → still deterministic, just not salted
  }
  return salt;
}

const pick = (pool, seed) => pool[hash(demoSalt() + String(seed).toLowerCase()) % pool.length];

const personFor = (seed) => pick(PEOPLE, seed);
// One index for both, so the company's name and its domain always match.
const companyIndex = (seed) => hash(demoSalt() + String(seed).toLowerCase()) % COMPANIES.length;
const domainFor = (seed) => COMPANIES[companyIndex(seed)];
const companyFor = (seed) => COMPANY_NAMES[companyIndex(seed)];

const looksLikeDomain = (v) => /^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(v.trim());

/**
 * Rewrite one address field — "Sarah Chen <s@x.com>", a bare address, a
 * comma-separated list, or (on an MX tab) a bare domain.
 */
// Split an address list on commas that are NOT inside a quoted display name:
// `"Doe, Jane" <j@x.com>` is one recipient, and a naive split leaked the "Doe
// fragment (no '@', so it fell through untouched).
const ADDRESS_LIST = /(?:"[^"]*"|[^,])+/g;

/** The bare address inside `Name <addr>`, or the trimmed value itself. */
function bareAddress(value) {
  const m = String(value).match(/<([^>]+)>\s*$/);
  return (m ? m[1] : String(value)).trim().toLowerCase();
}

function scrubAddresses(value) {
  return (value.match(ADDRESS_LIST) || [value])
    .map((part) => {
      const m = part.match(/^\s*"?(.*?)"?\s*<([^>]+)>\s*$/);
      const addr = (m ? m[2] : part).trim();
      if (!addr.includes('@')) return looksLikeDomain(addr) ? domainFor(addr) : part;
      const person = personFor(addr);
      return m && m[1] ? `${person.name} <${person.email}>` : person.email;
    })
    .join(', ');
}

function scrubFilename(value) {
  const dot = value.lastIndexOf('.');
  const ext = dot > 0 ? value.slice(dot) : '';
  const stem = dot > 0 ? value.slice(0, dot) : value;
  return pick(FILE_STEMS, stem) + ext;
}

// Keep the Re:/Fwd: prefix and seed on the bare subject, so a reply and the mail
// it answers land on the same stand-in and the thread still reads as a thread.
const REPLY_PREFIX = /^((?:(?:re|fw|fwd|aw|vs)\s*:\s*)+)/i;

// Which thread of the corpus a row becomes. Seeded on the BARE subject, so
// every message under one subject — and the conversation row above them — lands
// on the same thread, and `Re:` still reads as a reply to the mail above it.
function threadIndex(seed) {
  return hash(demoSalt() + String(seed).toLowerCase()) % THREADS.length;
}

/** The stand-in thread for a row: its label's Lore pool, else the general corpus. */
function threadFor(seed, label) {
  const key = String(seed || '').toLowerCase();
  const pool = label && LORE_BY_LABEL[label];
  if (pool) {
    const t = pool[hash(demoSalt() + key) % pool.length];
    LORE_PICKED.set(key, t);
    return t;
  }
  return LORE_PICKED.get(key) || THREADS[threadIndex(seed)];
}

function scrubSubject(value, label) {
  const prefix = value.match(REPLY_PREFIX)?.[1] || '';
  const bare = value.slice(prefix.length);
  const picked = threadFor(bare, label).subject;
  return prefix ? prefix + picked.replace(REPLY_PREFIX, '') : picked;
}

// Plain text keeps its blank lines; an HTML body has to carry real paragraphs,
// or the reading pane shows one run-on block.
const asHtml = (body) => body.split('\n\n').map((p) => `<p>${p.replace(/\n/g, '<br>')}</p>`).join('\n');

/**
 * The body text for one field. `seed` is the row's subject when it has one, so
 * the body matches the subject on screen; otherwise the field's own value, which
 * at least stays stable for that row.
 */
function scrubBody(key, value, subjectSeed, label) {
  const t = threadFor(subjectSeed || value, subjectSeed ? label : null);
  if (key === 'snippet' || key === 'preview' || key === 'ai_summary_short' || key === 'quote') return snippetOf(t);
  if (key === 'ai_summary' || key === 'ai_summary_medium' || key === 'description') return paragraphOf(t);
  if (key === 'body_html' || key === 'html_body') return asHtml(t.body);
  return t.body;
}

const ADDRESS_FIELDS = new Set([
  'from_address', 'to_address', 'cc_address', 'bcc_address', 'reply_to',
  'email', 'email_address', 'organizer_email', 'sender', 'recipient', 'address',
  'domain', 'domain_name', 'email_domain', // no '@' — these come back as a fake domain
  'from', 'to', 'cc', 'bcc',
]);
// Scrubbed only when the same object carries an address — "name" is also a
// folder, a Space, a tag and a domain, and those must survive untouched.
const NAME_FIELDS = new Set(['name', 'display_name', 'full_name', 'contact_name']);
// Always a person, address present or not.
const ALWAYS_NAME_FIELDS = new Set(['from_name', 'organizer_name', 'sender_name']);
const SUBJECT_FIELDS = new Set(['subject', 'normalized_subject', 'title', 'summary']);
const BODY_FIELDS = new Set([
  'snippet', 'preview', 'body', 'body_plain', 'body_html', 'body_text',
  'plain_body', 'html_body', 'description',
  'ai_summary', 'ai_summary_short', 'ai_summary_medium',
  'quote', // a mined Lore fact's source line
]);
// Columns that hold JSON, not text: calendar_events.metadata carries the real
// attendee list and the conference link, messages.meta_media the filenames.
// Parsed, scrubbed and re-stringified, so the consumers' JSON.parse still works.
const JSON_FIELDS = new Set(['metadata', 'meta_media']);

// A real join link is both a leak (it names the org) and a trap (clicking it in
// a demo drops you into a live meeting). Matched on the VALUE, not the field
// name, so it's caught wherever the provider hides it — metadata.conference.url,
// hangout_link, an entry point deep in a JSON blob.
const CONFERENCE_URL = /^https?:\/\/[^\s]*(meet\.google|teams\.microsoft|teams\.live|zoom\.us|webex\.com|whereby\.com|meet\.jit\.si)/i;
const FAKE_MEETING_URLS = PLACES.filter((p) => p.startsWith('http'));

// Real faces/logos would walk straight into the screenshot — drop them and let
// the initials avatar redraw from the fake name.
// icon_url included: an org's uploaded logo is as identifying as its name, and
// a caller that wants a placeholder can redraw one from the scrubbed name (see
// useAccounts).
const DROP_FIELDS = new Set(['from_avatar', 'avatar_url', 'profile_pic', 'icon_url', 'picture', 'photo_url']);

function scrubObject(obj) {
  // The person this row is about, so name and address agree.
  // Normalised to the bare address: `from_address` is often `Name <addr>`, and
  // hashing the whole string would pick a different person than scrubAddresses
  // does for the very same row — name and address disagreeing on one line.
  const seedField = [...ADDRESS_FIELDS]
    .map((f) => obj[f])
    .find((v) => typeof v === 'string' && v.includes('@'));
  const addressSeed = seedField ? bareAddress(seedField) : null;
  // Pairs the body with the subject (see scrubBody). A message row carries its
  // own subject; a conversation row carries the thread's.
  // An organisation/workspace row: a bare domain, no '@'. Its `name` is the
  // user's own company — as identifying as any address, and NOT a folder or
  // Space name, which is why those stay untouched.
  const orgSeed = ['domain', 'domain_name', 'email_domain', 'email_address', 'address']
    .map((f) => obj[f])
    .find((v) => typeof v === 'string' && v && !v.includes('@') && looksLikeDomain(v)) || null;
  const rawSubject = obj.subject || obj.normalized_subject || obj.title;
  const subjectSeed = typeof rawSubject === 'string' && rawSubject
    ? rawSubject.replace(REPLY_PREFIX, '')
    : null;
  const label = typeof obj.triage_label === 'string' ? obj.triage_label : null;
  const lore = subjectSeed ? threadFor(subjectSeed, label) : null;
  const entity = typeof obj.kind === 'string' && ENTITY_KINDS.has(obj.kind);
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    if (DROP_FIELDS.has(k)) out[k] = null;
    // Lore's next-action fields follow the stand-in thread, never the real mail.
    else if (k === 'next_action_title') out[k] = lore?.title || null;
    else if (k === 'next_action_amount_cents') {
      out[k] = lore?.amount_cents ?? (v == null ? null : DEMO_AMOUNTS[hash(demoSalt() + String(subjectSeed)) % DEMO_AMOUNTS.length]);
    } else if (k === 'next_action_currency') out[k] = v == null && lore?.amount_cents == null ? v : (lore?.currency || 'EUR');
    // An ontology entity's name by its kind (people → the cast, orgs → companies).
    else if (entity && k === 'name' && typeof v === 'string' && v) {
      if (obj.kind === 'person') out[k] = personFor(obj.address || v).name;
      else if (obj.kind === 'project') out[k] = pick(FAKE_PROJECTS, v);
      else out[k] = companyFor(obj.email_domain || v);
    } else if (k === 'value' && typeof v === 'string' && v && (obj.kind === 'attribute' || obj.kind === 'relation')) {
      out[k] = pick(FAKE_FACT_VALUES, v);
    }
    else if (typeof v !== 'string' || !v) out[k] = scrub(v);
    else if (ADDRESS_FIELDS.has(k)) out[k] = scrubAddresses(v);
    else if (ALWAYS_NAME_FIELDS.has(k)) out[k] = personFor(addressSeed || v).name;
    else if (NAME_FIELDS.has(k)) {
      if (looksLikeDomain(v)) out[k] = domainFor(v);
      else if (addressSeed) out[k] = personFor(addressSeed).name;
      else if (orgSeed) out[k] = companyFor(orgSeed); // an org/workspace, not a person
      else out[k] = v; // a folder / Space / tag name — leave it alone
    } else if (SUBJECT_FIELDS.has(k)) out[k] = scrubSubject(v, label);
    else if (BODY_FIELDS.has(k)) out[k] = scrubBody(k, v, subjectSeed, label);
    else if (k === 'location') out[k] = pick(PLACES, v);
    else if (CONFERENCE_URL.test(v)) out[k] = pick(FAKE_MEETING_URLS, v);
    else if (JSON_FIELDS.has(k)) out[k] = scrubJsonBlob(v);
    else if (k === 'filename' || k === 'name_on_disk') out[k] = scrubFilename(v);
    // messages.attachment_names is a space-joined list (see the engine schema).
    else if (k === 'attachment_names') out[k] = v.split(' ').map(scrubFilename).join(' ');
    else out[k] = v;
  }
  return out;
}

function scrubJsonBlob(value) {
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === 'object' ? JSON.stringify(scrub(parsed)) : value;
  } catch {
    return value; // not JSON after all — leave it exactly as it was
  }
}

/** Recursively replace every person-, subject- and body-shaped value. */
export function scrub(value) {
  if (Array.isArray(value)) return value.map(scrub);
  if (value && typeof value === 'object' && value.constructor === Object) return scrubObject(value);
  return value;
}

/** scrub(), but a no-op while demo mode is off — the form the read paths call. */
export function scrubIfDemo(value) {
  return isDemoMode() ? scrub(value) : value;
}
