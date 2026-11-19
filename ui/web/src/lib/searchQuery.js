// The search query — one structure, edited from two places.
//
// The search box speaks Gmail-style operators ("invoice from:ana has:attachment
// larger:5mb"); the Filters popover edits fields. Both are views of the same
// object, so they can't drift: parse() reads the string, format() writes it, and
// the URL only ever carries the string.
//
// Two translators consume the object — toSqlite() for the local-channel FTS
// query, toApiParams() for the Rails search endpoint.

import { CONV_STATUS, DISCARDED_STATUSES, statusNotIn } from './conversationStatus.js';

// Operators taking a free value, each repeatable (from:a from:b = either).
// `type` is a file extension ("type:pdf"): matched on the attachment's mime
// type where one is stored (MX) and on the filename's extension where one
// isn't (local channels index names, not mime types).
const LIST_FIELDS = ['from', 'to', 'cc', 'subject', 'filename', 'type'];
// Flags collected under is: / has:.
export const IS_FLAGS = ['read', 'unread', 'urgent', 'important', 'attachment'];
// Folder scope. 'anywhere' is the only one that reaches into trash/spam.
export const IN_SCOPES = ['inbox', 'archive', 'trash', 'spam', 'anywhere'];

export const EMPTY_QUERY = {
  text: '', from: [], to: [], cc: [], subject: [], filename: [], type: [],
  is: [], in: null, larger: null, smaller: null, after: null, before: null,
};

const SIZE_UNITS = { b: 1, k: 1e3, kb: 1e3, m: 1e6, mb: 1e6, g: 1e9, gb: 1e9 };

// "5mb" / "500kb" / "2M" / "1048576" → bytes, or null if it isn't a size.
export function parseSize(raw) {
  const m = String(raw).trim().match(/^(\d+(?:\.\d+)?)\s*([a-z]*)$/i);
  if (!m) return null;
  const unit = SIZE_UNITS[m[2].toLowerCase() || 'b'];
  return unit ? Math.round(parseFloat(m[1]) * unit) : null;
}

export function formatSize(bytes) {
  if (bytes == null) return '';
  if (bytes >= 1e9) return `${+(bytes / 1e9).toFixed(1)}gb`;
  if (bytes >= 1e6) return `${+(bytes / 1e6).toFixed(1)}mb`;
  if (bytes >= 1e3) return `${+(bytes / 1e3).toFixed(1)}kb`;
  return `${bytes}`;
}

// YYYY-MM-DD only — a natural-language date parser is a whole other project and
// the popover hands over a date input's value anyway.
const isDate = (v) => /^\d{4}-\d{2}-\d{2}$/.test(v);

/**
 * Parse a query string into the filter object. Anything that isn't a recognised
 * operator stays in `text` (so a stray colon still searches as words).
 */
export function parse(input) {
  const q = { ...EMPTY_QUERY, from: [], to: [], cc: [], subject: [], filename: [], type: [], is: [] };
  const text = [];
  // Tokens are bare words, "quoted phrases", or field:value / field:"quoted value".
  const tokens = String(input || '').match(/(?:[^\s"]+:)?"[^"]*"|\S+/g) || [];

  for (const token of tokens) {
    const at = token.indexOf(':');
    if (at <= 0) { text.push(token); continue; }
    const field = token.slice(0, at).toLowerCase();
    const value = unquote(token.slice(at + 1));
    if (!value) { text.push(token); continue; }

    if (LIST_FIELDS.includes(field)) { q[field].push(value); continue; }
    if (field === 'is' || field === 'has') {
      const flag = value.toLowerCase();
      if (IS_FLAGS.includes(flag)) { if (!q.is.includes(flag)) q.is.push(flag); }
      else text.push(token);
      continue;
    }
    if (field === 'in') {
      const scope = value.toLowerCase();
      if (IN_SCOPES.includes(scope)) q.in = scope; else text.push(token);
      continue;
    }
    if (field === 'larger' || field === 'smaller') {
      const bytes = parseSize(value);
      if (bytes != null) q[field] = bytes; else text.push(token);
      continue;
    }
    if (field === 'after' || field === 'before') {
      if (isDate(value)) q[field] = value; else text.push(token);
      continue;
    }
    text.push(token);
  }

  q.text = text.join(' ');
  return q;
}

/** The canonical string for a filter object — what the search box shows. */
export function format(q) {
  const parts = [];
  if (q.text) parts.push(q.text);
  for (const field of LIST_FIELDS) {
    for (const value of q[field] || []) parts.push(`${field}:${quote(value)}`);
  }
  for (const flag of q.is || []) parts.push(`${flag === 'attachment' ? 'has' : 'is'}:${flag}`);
  if (q.in) parts.push(`in:${q.in}`);
  if (q.larger != null) parts.push(`larger:${formatSize(q.larger)}`);
  if (q.smaller != null) parts.push(`smaller:${formatSize(q.smaller)}`);
  if (q.after) parts.push(`after:${q.after}`);
  if (q.before) parts.push(`before:${q.before}`);
  return parts.join(' ');
}

/** True when nothing but free text is set — the plain-search fast path. */
export function isBare(q) {
  return !LIST_FIELDS.some(f => q[f]?.length) && !q.is?.length
    && !q.in && q.larger == null && q.smaller == null && !q.after && !q.before;
}

// Every operator the user set, as removable chips (label + the key to clear).
export function chips(q) {
  const out = [];
  for (const field of LIST_FIELDS) {
    for (const value of q[field] || []) out.push({ key: `${field}:${value}`, field, value, label: `${field}: ${value}` });
  }
  for (const flag of q.is || []) out.push({ key: `is:${flag}`, field: 'is', value: flag, label: flag });
  if (q.in) out.push({ key: 'in', field: 'in', value: q.in, label: `in: ${q.in}` });
  if (q.larger != null) out.push({ key: 'larger', field: 'larger', value: q.larger, label: `larger than ${formatSize(q.larger)}` });
  if (q.smaller != null) out.push({ key: 'smaller', field: 'smaller', value: q.smaller, label: `smaller than ${formatSize(q.smaller)}` });
  if (q.after) out.push({ key: 'after', field: 'after', value: q.after, label: `after ${q.after}` });
  if (q.before) out.push({ key: 'before', field: 'before', value: q.before, label: `before ${q.before}` });
  return out;
}

/** Drop one chip's filter from the object (list fields drop just that value). */
export function without(q, { field, value }) {
  const next = { ...q };
  if (LIST_FIELDS.includes(field)) next[field] = (q[field] || []).filter(v => v !== value);
  else if (field === 'is') next.is = (q.is || []).filter(v => v !== value);
  else next[field] = null;
  return next;
}

// ── Backend translators ──────────────────────────────────────────────────────

// Folder scope → conversation statuses. 'anywhere' means no status filter at
// all; the default (null) hides trash/spam but keeps archived mail findable.
const SCOPE_STATUS = {
  inbox: [CONV_STATUS.OPEN],
  archive: [CONV_STATUS.ARCHIVED],
  trash: [CONV_STATUS.TRASH],
  spam: [CONV_STATUS.SPAM],
};

/**
 * SQL for the local-channel (SQLite) half of the search. Returns extra WHERE
 * fragments to AND onto the FTS query, plus their bound values. `startIndex` is
 * the first free ?N placeholder.
 *
 * `m` is the messages alias, `c` the conversations alias.
 */
export function toSqlite(q, startIndex = 1) {
  const where = [];
  const params = [];
  let n = startIndex;
  const bind = (value) => { params.push(value); return `?${n++}`; };
  // Address/filename operators match on a substring, case-insensitively — a
  // person is looked up as "ana", not as their full routing address.
  const anyLike = (col, values) =>
    `(${values.map(v => `${col} LIKE ${bind(`%${v.toLowerCase()}%`)}`).join(' OR ')})`;

  if (q.from?.length) where.push(anyLike('LOWER(m.from_address)', q.from));
  if (q.to?.length) where.push(anyLike('LOWER(m.to_address)', q.to));
  if (q.cc?.length) where.push(anyLike('LOWER(m.cc_address)', q.cc));
  if (q.subject?.length) where.push(anyLike('LOWER(c.subject)', q.subject));
  if (q.filename?.length) where.push(anyLike('LOWER(m.attachment_names)', q.filename));
  // Local channels store filenames, not mime types — an extension is the type.
  if (q.type?.length) where.push(anyLike('LOWER(m.attachment_names)', q.type.map(t => `.${t.replace(/^\./, '')}`)));

  if (q.is?.includes('attachment')) where.push('c.has_attachment = 1');
  if (q.is?.includes('read')) where.push('c.read = 1');
  if (q.is?.includes('unread')) where.push('c.read = 0');
  if (q.is?.includes('urgent')) where.push('c.priority_urgent = 1');
  if (q.is?.includes('important')) where.push('c.priority_important = 1');

  // Size lives on the message as its largest attachment (see the sync-side
  // `attachment_max_size`), which is exactly what "an attachment over 5MB" asks.
  if (q.larger != null) where.push(`m.attachment_max_size > ${bind(q.larger)}`);
  if (q.smaller != null) where.push(`m.attachment_max_size > 0 AND m.attachment_max_size < ${bind(q.smaller)}`);

  if (q.after) where.push(`c.updated_at >= ${bind(q.after)}`);
  // Inclusive of the named day: everything before the following midnight.
  if (q.before) where.push(`c.updated_at < ${bind(`${q.before}T23:59:59Z`)}`);

  const statuses = q.in ? SCOPE_STATUS[q.in] : null;
  if (statuses) where.push(`c.status IN (${statuses.map(s => bind(s)).join(', ')})`);
  else if (q.in !== 'anywhere') where.push(statusNotIn(DISCARDED_STATUSES, 'c.status'));

  return { where, params, nextIndex: n };
}

/**
 * Query params for the Rails search endpoint (the MX half). Only the free text
 * rides in `q`; operators go as their own allow-listed params (E4).
 */
export function toApiParams(q) {
  const params = {};
  for (const field of LIST_FIELDS) {
    if (q[field]?.length) params[field] = q[field].join(',');
  }
  if (q.is?.length) params.is = q.is.join(',');
  if (q.in) params.in = q.in;
  if (q.larger != null) params.larger = q.larger;
  if (q.smaller != null) params.smaller = q.smaller;
  if (q.after) params.after = q.after;
  if (q.before) params.before = q.before;
  return params;
}

function unquote(v) {
  return v.startsWith('"') && v.endsWith('"') ? v.slice(1, -1) : v;
}

function quote(v) {
  return /\s/.test(v) ? `"${v}"` : v;
}
