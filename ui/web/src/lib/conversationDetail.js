// Loading an external (Gmail/Microsoft) conversation's detail from local
// SQLite, then enriching each message with full bodies + attachments from the
// provider. This logic was copy-pasted across the per-account inbox, the
// unified inbox, and search results (and had already drifted); it lives here so
// the queries and the attachment shape stay in one place.

import { getDb } from './db.js';
import log from './log.js';

// Column lists for the base load. Kept here so the three readers can't drift.
const CONV_COLS =
  'key as id, key, subject, from_address, to_address, status, snippet, read, has_attachment, created_at, updated_at, ai_summary, ai_summary_msg_key, triage_label, triage_priority, from_avatar, channel, kind';
const MSG_COLS =
  'key as id, key, from_address, to_address, cc_address, subject, body_plain, body_html, is_inbound, is_draft, created_at';

// Load a conversation row + its messages (oldest first) from local SQLite.
// Returns { conv, messages } or null when the DB is unavailable / not found.
export async function loadConversationFromDb(convId) {
  const db = await getDb();
  if (!db) return null;
  const conv = await db.select(
    `SELECT ${CONV_COLS} FROM conversations WHERE key = ?1`,
    [convId]
  );
  if (conv.length === 0) return null;
  const messages = await db.select(
    `SELECT ${MSG_COLS} FROM messages WHERE conversation_key = ?1 ORDER BY created_at ASC`,
    [convId]
  );
  return { conv: conv[0], messages };
}

// Map a provider message's attachments onto the UI shape. `formatSize` lets the
// caller choose raw bytes vs a human string (the per-account inbox formats).
export function mapAttachments(attachments, msgKey, formatSize = (s) => s) {
  return (attachments || []).map(a => ({
    name: a.filename,
    size: formatSize(a.size),
    mimeType: a.mimeType,
    attachmentId: a.attachmentId,
    gmailMessageKey: msgKey,
  }));
}

// Load + enrich an external conversation, pushing updates through `onUpdate`
// (first the SQLite rows, then the provider-enriched bodies). `onEnriching`
// receives the in-flight message-key Set; `isStale()` lets the caller bail when
// the selection has moved on. Used by the unified inbox and search views; the
// per-account hook has its own cached variant built on the helpers above.
export async function loadAndEnrichExternalDetail(
  accountKey,
  convId,
  { onUpdate, onEnriching, isStale = () => false, logTag = 'ConvDetail', providerType = null }
) {
  try {
    const base = await loadConversationFromDb(convId);
    if (!base || isStale()) return;
    // `providerType` isn't a conversation column (it's account-derived) but the
    // detail render path branches on it (social chat vs email), so stamp it from
    // the caller's list row. The enriched update below preserves it via `prev`.
    onUpdate({ ...base.conv, providerType, accountKey, messages: base.messages });

    const { fetchMessage } = await import('./providers/index.js');
    onEnriching?.(new Set(base.messages.map(m => m.key)));
    const enriched = await Promise.all(
      base.messages.map(async (msg) => {
        try {
          const result = await fetchMessage(accountKey, msg.key);
          if (result) {
            const atts = mapAttachments(result.attachments, msg.key);
            return {
              ...msg,
              body_html: result.body_html || msg.body_html,
              body_plain: result.body_plain || msg.body_plain,
              attachments: atts.length > 0 ? atts : msg.attachments,
            };
          }
        } catch (e) {
          log.error(logTag, `enrich FAILED ${msg.key}: ${e?.message || e}`);
        }
        return msg;
      })
    );
    if (isStale()) return;
    onEnriching?.(new Set());
    onUpdate(prev => (prev?.id === base.conv.id ? { ...prev, messages: enriched } : prev));
  } catch (e) {
    if (!isStale()) log.warn(logTag, `Failed to load conversation: ${e?.message || e}`);
  }
}
