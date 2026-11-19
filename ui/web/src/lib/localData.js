// Local-first data layer for the Tauri desktop client: MX mail, read from the
// engine's local mirror (docs/MX-Sync.md) instead of over the network.
//
// The Rust engine keeps the `mx_*` tables current (sync/pull, backfill, reconcile
// — see lib/mxMirror.js for what drives it). Every row carries the API's own
// serialized record in `payload`, so these functions return exactly what the
// matching endpoint would: callers can't tell the difference, which is the point.
//
// Every function returns `null` for "can't answer this locally" — not mirrored
// yet, a filter only the server can evaluate, or not running in Tauri — and the
// caller (localFirstApi) falls through to the API. `null` never means "empty":
// a fully-mirrored org with no matching mail returns an empty list.

import { isTauri } from './tauri.js';
import { getDb } from './db.js';
import { isDemoMode, scrubIfDemo } from './demoData.js';
import { CONV_STATUS, INBOX_HIDDEN_STATUSES } from './conversationStatus.js';
import mxMirror from './mxMirror.js';

// Callers name an org by key (org_…) or by slug; the mirror is keyed by key.
// Only a COMPLETE mirror is served — while history is still being read a local
// page would silently miss whatever hasn't arrived, so the API answers instead.
async function mirrorFor(database, orgId) {
  const rows = await database.select(
    `SELECT s.organization_id AS org FROM mx_sync_state s
      WHERE s.backfill_done = 1 AND s.user_key = ?2 AND (s.organization_id = ?1 OR EXISTS (
        SELECT 1 FROM mx_directory d
         WHERE d.organization_id = s.organization_id AND d.type = 'organization'
           AND json_extract(d.payload, '$.slug') = ?1))`,
    // Visibility is per member: a mirror built for another user (they signed in
    // here before; the engine hasn't wiped it yet) is never served to this one.
    [orgId, mxMirror.userKey || '']
  );
  return rows[0]?.org || null;
}

// The mirrored org's key for a key-or-slug, complete or not — null when this org
// isn't mirrored here at all.
export async function mirroredOrg(orgId) {
  if (!isTauri()) return null;
  const database = await getDb();
  if (!database) return null;
  const rows = await database.select(
    `SELECT s.organization_id AS org FROM mx_sync_state s
      WHERE s.organization_id = ?1 OR EXISTS (
        SELECT 1 FROM mx_directory d
         WHERE d.organization_id = s.organization_id AND d.type = 'organization'
           AND json_extract(d.payload, '$.slug') = ?1)`,
    [orgId]
  );
  return rows[0]?.org || null;
}

async function open(orgId) {
  if (!isTauri()) return null;
  const database = await getDb();
  if (!database) return null;
  const org = await mirrorFor(database, orgId);
  return org ? { database, org } : null;
}

// Demo mode: db.js scrubs SQL rows by column, but a payload is one opaque JSON
// string to it — so the parsed records go through the same scrubber the API
// responses do. Without this a demo would show real MX mail.
const parse = (rows) => scrubIfDemo(rows.map(r => JSON.parse(r.payload)));

// List filters the mirror can evaluate. Anything else in `params` (view_id,
// direction, is_draft, mentioned, assignee, …) is server-only → null.
const LOCAL_PARAMS = new Set(['status', 'domain', 'space', 'tags', 'tag', 'read', 'to', 'from', 'page', 'per_page', 'include_sent']);

// Conversations — mirrors ConversationsController#index.

export async function getConversations(orgId, params = {}) {
  const active = Object.keys(params).filter(k => params[k] != null && params[k] !== '');
  if (active.some(k => !LOCAL_PARAMS.has(k))) return null;
  const m = await open(orgId);
  if (!m) return null;

  const where = ['organization_id = ?'];
  const binds = [m.org];
  if (params.status) {
    where.push('status = ?');
    binds.push(params.status);
  } else {
    // The API's default: never surface trashed, spam or archived threads.
    where.push(`status NOT IN (${INBOX_HIDDEN_STATUSES.map(() => '?').join(', ')})`);
    binds.push(...INBOX_HIDDEN_STATUSES);
  }
  // The API's Inbox rule (ConversationsController#inbox_listing?).
  if (!params.include_sent && (!params.status || params.status === CONV_STATUS.OPEN)) {
    where.push(`COALESCE(json_extract(payload, '$.sent_only'), 0) = 0`);
  }
  if (params.domain) {
    // dom_ key, or the domain's slug / name (the API resolves all three).
    where.push(`(domain_key = ? OR domain_key IN (
      SELECT key FROM mx_directory WHERE organization_id = ? AND type = 'domains'
         AND (json_extract(payload, '$.slug') = ? OR json_extract(payload, '$.name') = ?)))`);
    binds.push(params.domain, m.org, params.domain, params.domain);
  }
  if (params.space) {
    where.push(`(json_extract(payload, '$.space.id') = ? OR space_slug = ?)`);
    binds.push(params.space, params.space);
  }
  const tags = [].concat(params.tags || [], params.tag || []).filter(Boolean);
  if (tags.length) {
    where.push(`EXISTS (SELECT 1 FROM json_each(payload, '$.tags') t
                 WHERE json_extract(t.value, '$.name') IN (${tags.map(() => '?').join(', ')}))`);
    binds.push(...tags);
  }
  if (params.read != null && params.read !== '') {
    where.push('read = ?');
    binds.push(String(params.read) === 'true' ? 1 : 0);
  }
  if (params.to) { where.push('to_address = ?'); binds.push(params.to); }
  if (params.from) { where.push('from_address = ?'); binds.push(params.from); }

  const perPage = Math.min(Number(params.per_page) || 25, 100);
  const page = Math.max(Number(params.page) || 1, 1);
  const filter = where.join(' AND ');
  const rows = await m.database.select(
    `SELECT payload FROM mx_conversations WHERE ${filter}
      ORDER BY updated_at DESC, key DESC LIMIT ? OFFSET ?`,
    [...binds, perPage, (page - 1) * perPage]
  );
  const [{ total }] = await m.database.select(
    `SELECT COUNT(*) AS total FROM mx_conversations WHERE ${filter}`, binds
  );
  return {
    conversations: parse(rows),
    meta: { page, per_page: perPage, total, total_pages: Math.ceil(total / perPage) },
    _source: 'local'
  };
}

// One thread with its messages and notes — mirrors ConversationsController#show.
// A thread the mirror holds only as a list row (not hydrated yet) goes to the API.
export async function getConversation(orgId, convId) {
  const m = await open(orgId);
  if (!m) return null;
  const rows = await m.database.select(
    'SELECT payload FROM mx_conversations WHERE key = ? AND organization_id = ? AND hydrated = 1',
    [convId, m.org]
  );
  if (rows.length === 0) return null;

  const [conversation] = parse(rows);
  const children = (table) => m.database.select(
    `SELECT payload FROM ${table} WHERE conversation_key = ? ORDER BY created_at ASC, key ASC`, [convId]
  );
  const [messages, notes, members] = await Promise.all([
    children('mx_messages'), children('mx_notes'), directory(m, 'members'),
  ]);
  // The list row names assignees compactly; the detail endpoint returns the full
  // member. Same people, richer record — take it from the mirrored directory.
  const byId = new Map(members.map(x => [x.id, x]));
  return {
    conversation: {
      ...conversation,
      assignees: (conversation.assignees || []).map(a => byId.get(a.id) || a),
      messages: parse(messages),
      notes: parse(notes),
    },
    _source: 'local'
  };
}

async function directory(m, type) {
  return parse(await m.database.select(
    'SELECT payload FROM mx_directory WHERE organization_id = ? AND type = ? ORDER BY position', [m.org, type]
  ));
}

// Directory listings — exactly what the index endpoints returned, in their order.

export async function getTags(orgId) {
  const m = await open(orgId);
  return m ? { tags: await directory(m, 'tags'), _source: 'local' } : null;
}

export async function getMembers(orgId) {
  const m = await open(orgId);
  return m ? { members: await directory(m, 'members'), _source: 'local' } : null;
}

// Views — always from the API (its counts are live server aggregates).
export async function getViews() {
  return null;
}

// User text → an FTS5 query that can't be a syntax error: every word quoted (so
// AND, -, : and friends are just characters) and prefix-matched. Mirrors
// `fts_query` in the engine's store/mx.rs.
export function ftsQuery(input) {
  const words = String(input || '').split(/\s+/)
    .map(w => w.replaceAll('"', ''))
    .filter(w => /[\p{L}\p{N}]/u.test(w))
    .map(w => `"${w}"*`);
  return words.length ? words.join(' ') : null;
}

// Search — the mirror's own full-text index (`mx_messages_fts`, maintained by the
// engine). Works offline, and reaches sealed mail the engine has opened, which the
// server can never index. Trash and spam never match, like the server's search.
export async function searchLocal(orgId, query) {
  const m = await open(orgId);
  if (!m) return null;
  const match = ftsQuery(query);
  if (!match) return { conversations: [], _source: 'local' };
  const rows = await m.database.select(
    `SELECT c.payload FROM mx_conversations c
      WHERE c.organization_id = ?1 AND c.status NOT IN ('trash', 'spam')
        AND c.key IN (SELECT msg.conversation_key FROM mx_messages_fts f
                        JOIN mx_messages msg ON msg.id = f.rowid
                       WHERE mx_messages_fts MATCH ?2 AND msg.organization_id = ?1)
      ORDER BY c.updated_at DESC, c.key DESC LIMIT 50`,
    [m.org, match]
  );
  return { conversations: parse(rows), _source: 'local' };
}

/**
 * Persist a client-side AI thread summary to local SQLite (Tauri only).
 * msgKey is the conversation's latest message key at generation time, used to
 * detect staleness. Fire-and-forget — errors are silently ignored. Not queued
 * for sync: AI artifacts are local-only and never touch the API.
 */
export async function persistConversationSummary(convId, summary, msgKey) {
  if (!isTauri()) return;
  // Demo mode: this summary was generated from SCRUBBED text, so writing it back
  // would overwrite a real thread's summary with one about fictional people —
  // damage that outlives the demo. The in-memory cache still holds it.
  if (isDemoMode()) return;
  try {
    const database = await getDb();
    if (!database) return;
    await database.execute(
      'UPDATE conversations SET ai_summary = ?, ai_summary_msg_key = ? WHERE key = ?',
      [summary || null, msgKey || null, convId]
    );
  } catch {
    // Non-critical — in-memory cache still works
  }
}
