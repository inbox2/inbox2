// The menu bar popover's mail read: the newest unread inbox threads across every
// account. Same two paths as everywhere else — local channels from SQLite, MX
// through the local-first API — and the same inbox test the unread badge uses
// (useChannelUnreadCounts), so the list can't show a thread the badge ignores.

import { getDb } from './db.js';
import { INBOX_HIDDEN_STATUSES, CONV_STATUS, statusNotIn } from './conversationStatus.js';
import { FOLDER_ROLE } from './folderRoles.js';
import { PROVIDER } from './providerTypes.js';
import { isTauri } from './tauri.js';
import api from './localFirstApi.js';
import log from './log.js';

const row = (c, accountKey, summary) => ({
  key: c.key || c.id,
  accountKey,
  subject: c.subject || '',
  from_address: c.from_address || '',
  summary: summary || c.snippet || '',
  updated_at: c.updated_at || c.created_at || '',
});

async function localUnread(limit) {
  const db = await getDb();
  if (!db) return [];
  const rows = await db.select(
    `SELECT c.key, c.organization_id, c.subject, c.from_address, c.snippet, c.ai_summary, c.updated_at
     FROM conversations c
     WHERE c.read = 0 AND ${statusNotIn(INBOX_HIDDEN_STATUSES, 'c.status')}
       AND EXISTS (
         SELECT 1 FROM messages m
         JOIN message_provider_state mps ON mps.message_key = m.key
         JOIN external_folders ef ON ef.key = mps.folder_key
         WHERE m.conversation_key = c.key
           AND mps.account_key = c.organization_id
           AND ef.well_known_role = '${FOLDER_ROLE.INBOX}'
       )
     ORDER BY c.updated_at DESC LIMIT ?1`,
    [limit]
  );
  return rows.map((c) => row(c, c.organization_id, c.ai_summary));
}

async function mxUnread(acct, limit) {
  const isDomain = acct.domainKey?.startsWith('dom_');
  const params = { status: CONV_STATUS.OPEN, read: 'false', per_page: limit };
  if (isDomain) params.domain = acct.domainKey;
  const data = await api.getConversations(isDomain ? (acct.orgSlug || acct.key) : acct.key, params);
  return (data?.conversations || []).map((c) => row(c, acct.key, c.ai_summary_short));
}

export function mergeLatest(lists, limit) {
  return lists.flat()
    .sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)))
    .slice(0, limit);
}

export async function fetchLatestUnread(accounts, limit = 5) {
  const reads = (accounts || [])
    .filter((a) => a.provider_type === PROVIDER.INBOX2)
    .map((a) => mxUnread(a, limit));
  if (isTauri()) reads.push(localUnread(limit));
  const settled = await Promise.allSettled(reads);
  for (const r of settled) if (r.status === 'rejected') log.warn('Tray', `unread read failed: ${r.reason?.message || r.reason}`);
  return mergeLatest(settled.filter((r) => r.status === 'fulfilled').map((r) => r.value), limit);
}
