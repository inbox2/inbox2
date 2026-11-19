// The Spaces board (SpaceDashboard) data model — pure, so the merge/sort rules
// are unit-tested. useSpaceBoard does the fetching; this turns the MX (API) and
// local (SQLite) results into treemap cells + per-cell rows.
//
//   Mine: the viewer's own mail — their connected-account threads plus MX
//         threads assigned to them. Cells: org Spaces + personal Spaces
//         (desktop) + the holding pen.
//   Team: the org's shared MX mail from everyone. Never local rows (private).
import { conversationPreview } from './conversationPreview';
import { CONV_STATUS, KEPT_STATUSES, INBOX_HIDDEN_STATUSES, DISCARDED_STATUSES, statusNotIn } from './conversationStatus';
import { triageBadge, priorityChip } from './triage';
import { FOLDER_ROLE } from './folderRoles';

export const BOARD_VIEW = { MINE: 'mine', TEAM: 'team' };
// Values double as the Space stat keys (spaces.open / .volume / .unread).
export const BOARD_METRIC = { OPEN: 'open', ALL: 'volume', UNREAD: 'unread' };
export const HOLDING_PEN_SLUG = 'triage';
// Personal-Space openness marker (org Spaces are 'org' | 'assigned').
export const OPENNESS_PERSONAL = 'personal';
// ponytail: rows per Space per source; the cell's count stays exact (API
// meta.total / SQL COUNT), only the listed rows stop here.
export const ROW_CAP = 200;

// "Maya Chen <maya@acme.com>" / "maya@acme.com" → a compact display name.
export function fromName(addr) {
  if (!addr) return '';
  const named = addr.match(/^\s*"?([^"<]+?)"?\s*</);
  if (named) return named[1].trim();
  const at = addr.indexOf('@');
  return at > 0 ? addr.slice(0, at) : addr;
}

export function shortDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

/** Conversations-index params for a metric (MX). Unread = open and unread,
 *  matching the /spaces stats; All items never includes trash or spam. */
export function mxQuery(metric) {
  if (metric === BOARD_METRIC.ALL) return { status: KEPT_STATUSES };
  if (metric === BOARD_METRIC.UNREAD) return { status: CONV_STATUS.OPEN, read: 'false' };
  return { status: CONV_STATUS.OPEN };
}

/** SQL WHERE fragment over `c.` for a metric (local). Constants only. */
// Local threads that are really in an inbox: a message sits in the account's
// inbox folder. `status = open` alone isn't enough — sent-only threads and mail
// filed in other folders are "open" too (the inbox list drives from this join).
const IN_INBOX = `c.key IN (
  SELECT m.conversation_key FROM message_provider_state mps
  JOIN messages m ON m.key = mps.message_key
  JOIN external_folders f ON f.account_key = mps.account_key AND f.key = mps.folder_key
  WHERE f.well_known_role = '${FOLDER_ROLE.INBOX}')`;

/**
 * SQL filter for the local rows of a metric: Open/Unread = what the inbox shows
 * (in an inbox folder, not archived/trash/spam); All items = that plus archived
 * mail. Trash and spam never appear.
 */
export function localWhere(metric) {
  if (metric === BOARD_METRIC.ALL) {
    return `${statusNotIn(DISCARDED_STATUSES, 'c.status')}
               AND (c.status = '${CONV_STATUS.ARCHIVED}' OR ${IN_INBOX})`;
  }
  const inbox = `${statusNotIn(INBOX_HIDDEN_STATUSES, 'c.status')} AND ${IN_INBOX}`;
  return metric === BOARD_METRIC.UNREAD ? `${inbox} AND c.read = 0` : inbox;
}

const ts = (iso) => Date.parse(iso) || 0;
const score = (p) => (p == null || p === '' || Number.isNaN(Number(p)) ? -1 : Number(p));

/** API conversation → board row. */
export function mxRow(c) {
  const at = c.updated_at || c.created_at;
  return {
    id: c.id,
    from: fromName(c.from_address),
    subject: c.subject || '(no subject)',
    preview: conversationPreview(c),
    provider: 'inbox2',
    date: shortDate(at),
    at: ts(at),
    attachment: !!c.has_attachment,
    unread: c.read === false,
    label: c.triage_label || null,
    priority: score(c.triage_priority),
    assignees: (c.assignees || []).map((a) => ({ id: a.id, name: a.name })),
  };
}

/** Local SQLite row → board row (accountKey routes the click + actions). */
export function localRow(r) {
  return {
    id: r.key,
    accountKey: r.account_key,
    from: fromName(r.from_address),
    subject: r.subject || '(no subject)',
    preview: conversationPreview(r),
    provider: r.provider_type || 'imap',
    date: shortDate(r.updated_at),
    at: ts(r.updated_at),
    attachment: false,
    unread: r.read === 0,
    label: r.triage_label || null,
    priority: score(r.triage_priority),
    assignees: [],
  };
}

/** Highest Jev priority first (untriaged last), then newest. */
export function compareRows(a, b) {
  return (b.priority - a.priority) || (b.at - a.at);
}

/** Personal Spaces (get_personal_spaces) → cells, skipping any slug an org
 *  Space already owns. */
export function personalCells(list, orgSpaces) {
  const taken = new Set(orgSpaces.map((s) => s.id));
  return (list || [])
    .filter((p) => p?.slug && !taken.has(p.slug))
    .map((p) => ({
      id: p.slug,
      key: null,
      slug: p.slug,
      name: p.name || p.slug,
      description: p.description || '',
      openness: OPENNESS_PERSONAL,
      members: [],
      open: 0,
      unread: 0,
      volume: 0,
    }));
}

/**
 * Build the board for one view + metric.
 *   spaces     — org Spaces (useSpaces), holding pen included
 *   personal   — personal Space cells (Mine only; personalCells())
 *   mx / local — { [slug]: { total, rows: [raw…] } } per source
 *   labels     — { local, org } triage label lists for custom-label names
 * Returns { cells, rowsBySlug }: cells carry `[metric]` = the view's count;
 * rows are decorated with `labelChip` / `priorityChip` and sorted.
 */
export function buildBoard({ view, metric, spaces, personal = [], mx = {}, local = {}, labels = {} }) {
  const team = view === BOARD_VIEW.TEAM;
  // Personal cells sit before the holding pen, which stays last.
  const pen = spaces.filter((s) => s.id === HOLDING_PEN_SLUG);
  const cellsIn = team ? spaces : [...spaces.filter((s) => s.id !== HOLDING_PEN_SLUG), ...personal, ...pen];
  const rowsBySlug = {};
  const cells = cellsIn.map((s) => {
    const m = mx[s.id];
    const l = team ? null : local[s.id];
    const rows = [
      ...(m?.rows || []).map(mxRow),
      ...(l?.rows || []).map(localRow),
    ].map((r) => ({
      ...r,
      labelChip: triageBadge(r.label, r.accountKey ? labels.local : labels.org),
      priorityChip: priorityChip(r.priority < 0 ? null : r.priority),
      // Avatars only mean something on the Team board; Mine is all "me".
      assignees: team ? r.assignees : [],
    })).sort(compareRows);
    rowsBySlug[s.id] = rows;
    // Before the MX fetch lands, Team can show the Space's own stat (same
    // definition); Mine has no such number, so it starts from the local count.
    const mxCount = m ? m.total : (team ? (s[metric] || 0) : 0);
    return {
      ...s,
      [metric]: mxCount + (l?.total || 0),
      // The unassigned pile is a team notion: Mine is already yours.
      unassigned: team ? s.unassigned : null,
    };
  });
  return { cells, rowsBySlug };
}
