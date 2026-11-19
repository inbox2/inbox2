import { getDb } from '../lib/db.js';
import { CONV_STATUS, INBOX_HIDDEN_STATUSES, statusNotIn } from '../lib/conversationStatus.js';
import { FOLDER_ROLE } from '../lib/folderRoles.js';
import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import syncManager from '../lib/sync-manager';
import api from '../lib/localFirstApi';
import { isTauri } from '../lib/tauri';
import { getQuadrant, PRIORITY_URGENT, PRIORITY_IMPORTANT, PRIORITY_LATER } from '../lib/priority';
import { setMxPriorityTags, clearMxPriorityTags } from '../lib/mxPriority';
import useSyncRefresh from './useSyncRefresh';
import useMailRefresh from './useMailRefresh';
import useRefetchOnFocus from './useRefetchOnFocus';
import log from '../lib/log';
import useUndoStore from '../stores/undoStore';
import useUnreadStore from '../stores/unreadStore';
import { CONV_ACTION, REVERSE_VERB, REMOVAL_ACTIONS, REMOVAL_PAST_TENSE, ACTION_ICON, STATUS_FORWARD_ACTION, commitAction, unreadDelta } from '../lib/conversationActions';

// Rows per column page. Every column pages the same way (MX over the API, local
// channels over SQLite) so no lane silently ends earlier than its neighbours —
// they used to stop at 25 and 200 respectively, whichever the fetch happened to
// cap at. Pages beyond the first are appended as the user scrolls that column.
//
// Two screens' worth per column: enough to scroll into, small enough that the
// default landing view isn't waiting on hundreds of rows across every channel.
// The Eisenhower matrix does NOT depend on this depth — it's fed by its own
// triaged query (see fetchAccount), because a thread triaged weeks ago sits far
// below any first page.
const COLUMN_PAGE_SIZE = 50;

// A local row is triaged if it carries a priority flag, or the explicit "Later"
// marker (that quadrant has no flags, so without it a Later placement reads back
// as untriaged). Mirrors `normalize` below — keep the two in step.
const LOCAL_TRIAGED_SQL =
  '(c.priority_urgent = 1 OR c.priority_important = 1 OR c.priority_triaged = 1)';

// First occurrence of each id wins — a thread can arrive from both the stream
// page and the triaged query, and offset paging over a moving list repeats rows.
function dedupeById(convs) {
  const seen = new Set();
  return convs.filter(c => (seen.has(c.id) ? false : seen.add(c.id)));
}

/**
 * Normalize a conversation from any source into a unified shape.
 * `orgKey` (inbox2 only): the org identifier for API calls — the column's
 * accountKey is a domain id, which /orgs/:id does not resolve.
 */
export function normalize(conv, accountKey, providerType, orgKey = null) {
  const tags = conv.tags || [];
  // Org accounts: priority stored as tags; external accounts: stored as SQLite columns
  const urgent = providerType === 'inbox2'
    ? tags.some(t => t.name === PRIORITY_URGENT)
    : !!conv.priority_urgent;
  const important = providerType === 'inbox2'
    ? tags.some(t => t.name === PRIORITY_IMPORTANT)
    : !!conv.priority_important;
  // "Later" has no priority flags, so it carries an explicit marker: a Later
  // tag (org) or the priority_triaged column (external). Without it a Later
  // placement reads back as untriaged and disappears on the next refresh.
  const later = providerType === 'inbox2'
    ? tags.some(t => t.name === PRIORITY_LATER)
    : !!conv.priority_triaged;
  // Triaged if explicitly assigned to any quadrant (a priority flag, or Later).
  const triaged = urgent || important || later;

  return {
    id: conv.id || conv.key,
    key: conv.key || conv.id,
    accountKey,
    orgKey,
    providerType,
    subject: conv.subject || '',
    from_address: conv.from_address || '',
    to_address: conv.to_address || '',
    snippet: conv.snippet || '',
    read: !!conv.read,
    status: conv.status || CONV_STATUS.OPEN,
    updated_at: conv.updated_at || conv.created_at || '',
    created_at: conv.created_at || '',
    tags,
    has_attachment: !!conv.has_attachment,
    message_count: conv.message_count || 1,
    // Meta surface/event + sender avatar — drive the social chat/comment/list
    // rendering (null for email/MX, which keeps the email render path).
    channel: conv.channel || null,
    kind: conv.kind || null,
    from_avatar: conv.from_avatar || null,
    urgent,
    important,
    triaged,
    quadrant: triaged ? getQuadrant(urgent, important) : null,
  };
}

/**
 * Hook that fetches conversations from ALL connected accounts and merges
 * them into a single, sorted, filterable stream. Each account loads
 * independently — its column merges into the stream as soon as it lands.
 *
 * @param {Array} accounts - per-domain MX tabs + external accounts, from
 *   useAccounts. MX entries carry orgSlug/domainKey (key = domain id).
 * @param {Object} [spaceFilter] - { slug, key } narrows every channel to one
 *   Space (treemap drill-in): MX via the API `space` param (spc_ key), local
 *   channels via the on-device classifier's `space_slug` column. Open threads
 *   only — archived/trashed/spammed are "done" and leave the space.
 */
export default function useUnifiedInbox(accounts, onRestoreSelect, spaceFilter = null) {
  // Latest re-select callback, read lazily inside undo so we don't thread it
  // through every memoized action. Lets undo move the cursor back to the
  // restored conversation (cmd+z or the toast's Undo button).
  const onRestoreSelectRef = useRef(onRestoreSelect);
  useEffect(() => { onRestoreSelectRef.current = onRestoreSelect; }, [onRestoreSelect]);

  const [allConversations, setAllConversations] = useState([]);
  // Latest list, read by the action dispatcher without widening its deps (undo/
  // redo hold onto a recorded closure, which would otherwise see a stale list).
  const convsRef = useRef([]);
  useEffect(() => { convsRef.current = allConversations; }, [allConversations]);
  const [disabledChannels, setDisabledChannels] = useState(new Set());
  const [priorityFilter, setPriorityFilter] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const fetchedRef = useRef(false);
  // True once the first fetch has populated the list. Background refreshes
  // (sync events, post-archive refetch) keep the current list on screen
  // instead of flashing the full-screen loading state — stale-while-revalidate.
  const loadedOnceRef = useRef(false);

  // Derive channel states from accounts + disabled set
  const channelStates = useMemo(() => {
    const states = {};
    for (const acct of accounts) {
      states[acct.key] = {
        enabled: !disabledChannels.has(acct.key),
        account: acct,
      };
    }
    return states;
  }, [accounts, disabledChannels]);

  // Last good result per account, so a transient failure falls back to the
  // previous data instead of blanking the column (stale-while-revalidate).
  const lastGoodRef = useRef({});
  // How deep each column is scrolled: { page, ended, loading } by account key.
  // A ref, not state — nothing renders off it, and a page-1 refresh has to read
  // the current depth while it merges its result in.
  const columnPagesRef = useRef({});
  const columnState = useCallback((key) => (
    columnPagesRef.current[key] ||= { page: 1, ended: false, loading: false }
  ), []);

  // Guards against overlapping fetchAll runs (initial effect + accounts effect +
  // sync refresh all fire during boot); coalesces them so they don't pile
  // concurrent queries onto an already-contended DB.
  const inFlightRef = useRef(false);
  const rerunRef = useRef(false);
  const fetchAllRef = useRef(null);

  // Space drill: elect one MX tab per org to fetch the org-wide pool (the Space
  // filter overrides per-domain narrowing — see fetchAccount). Shared by the
  // first page and by load-more, so a column can't switch roles mid-scroll.
  const spaceOwners = useMemo(() => {
    const owners = new Set();
    if (!spaceFilter) return owners;
    const seen = new Set();
    for (const a of accounts) {
      if (a.provider_type !== 'inbox2') continue;
      const org = a.orgSlug || a.key;
      if (!seen.has(org)) { seen.add(org); owners.add(a.key); }
    }
    return owners;
  }, [accounts, spaceFilter]);

  // Fetch one account's inbox, retrying transient errors. SQLite is heavily
  // contended during the initial sync's write burst, so a first attempt can
  // throw (SQLITE_BUSY) — retry a few times before giving up. Returns
  // ok=false only after retries are exhausted.
  //
  // `triagedOnly` fetches the column's TRIAGED threads instead of a page of its
  // stream. Those live in the Eisenhower matrix, not the stream, and a thread
  // triaged weeks ago sits far below the first page — deriving the matrix from
  // the loaded pages silently dropped everything past the page size. This is one
  // extra query per column, always page 1: a triage pile is small by nature.
  // ponytail: capped at one page (100). Page it too if a real matrix ever
  // outgrows that — the count in each quadrant would under-report first.
  //
  // `unreadOnly` is the same idea for the unread view: every unread inbox thread,
  // however old, so a lane agrees with its badge.
  const fetchAccount = useCallback(async (acct, spaceOwner = false, page = 1, { triagedOnly = false, unreadOnly = false } = {}) => {
    const subset = triagedOnly || unreadOnly;
    for (let attempt = 0; ; attempt++) {
      try {
        let convs = [];
        if (acct.provider_type === 'inbox2') {
          if (spaceFilter && (!spaceFilter.key || !spaceOwner)) {
            // Space drill: Spaces are org-wide (a thread may even have no
            // domain), so the Space filter overrides the per-domain narrowing —
            // one tab per org (the spaceOwner) fetches the whole pool and the
            // other domain tabs sit out to avoid duplicate rows. A space with
            // no MX key (local-only slug) has nothing org-side at all.
            lastGoodRef.current[acct.key] = [];
            return { ok: true, convs: [] };
          }
          // Per-domain tab: fetch the org pool (by slug — /orgs/:id doesn't
          // resolve dom_ ids) narrowed to this domain, same as
          // useChannelUnreadCounts. Legacy single-domain tabs have no dom_ key.
          const orgId = acct.orgSlug || acct.key;
          const params = { status: CONV_STATUS.OPEN, per_page: COLUMN_PAGE_SIZE, page };
          // Priority is stored as tags on MX, so the triaged set IS the threads
          // carrying one of them (OR'd server-side by the tags[] filter).
          if (triagedOnly) params.tags = [PRIORITY_URGENT, PRIORITY_IMPORTANT, PRIORITY_LATER];
          if (unreadOnly) params.read = 'false';
          if (spaceFilter) params.space = spaceFilter.key;
          else if (acct.domainKey?.startsWith('dom_')) params.domain = acct.domainKey;
          const data = await api.getConversations(orgId, params);
          convs = (data.conversations || []).map(c => normalize(c, acct.key, 'inbox2', orgId));
        } else if (isTauri() && spaceFilter) {
          // Local channel narrowed to a Space: by the on-device classifier's
          // space_slug. Open only — same "done leaves the space" rule as MX.
          const db = await getDb();
          const rows = await db.select(
            `SELECT c.key as id, c.key, c.subject, c.from_address, c.to_address,
                    c.status, c.snippet, c.read, c.has_attachment,
                    c.priority_urgent, c.priority_important, c.priority_triaged,
                    c.created_at, c.updated_at,
                    (SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = c.key) AS message_count
             FROM conversations c
             WHERE c.organization_id = ?1
               AND c.space_slug = ?2
               AND ${statusNotIn(INBOX_HIDDEN_STATUSES, 'c.status')}
               ${triagedOnly ? `AND ${LOCAL_TRIAGED_SQL}` : ''}
               ${unreadOnly ? 'AND c.read = 0' : ''}
             ORDER BY c.updated_at DESC LIMIT ?3 OFFSET ?4`,
            [acct.key, spaceFilter.slug, COLUMN_PAGE_SIZE, (page - 1) * COLUMN_PAGE_SIZE]
          );
          convs = rows.map(c => normalize(c, acct.key, acct.provider_type));
        } else if (isTauri()) {
          const db = await getDb();
          // Inbox = conversations with a message in the account's inbox folder.
          // Drive from the indexed (account_key, folder_key) inbox set rather than
          // joining/scanning every message: inbox membership reliably lives in an
          // mps row whose folder_key is the inbox folder (verified across
          // Gmail/MS/IMAP — the labels-LIKE alternative finds nothing folder_key
          // doesn't), so the unindexable `labels LIKE` and the JOIN+DISTINCT
          // row-explosion are both avoidable. Reads ~the inbox set, not all the
          // account's conversations (which for a large archive was a ~2s scan).
          const rows = await db.select(
            `SELECT c.key as id, c.key, c.subject, c.from_address, c.to_address,
                    c.status, c.snippet, c.read, c.has_attachment,
                    c.priority_urgent, c.priority_important, c.priority_triaged,
                    c.created_at, c.updated_at,
                    (SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = c.key) AS message_count
             FROM conversations c
             WHERE c.organization_id = ?1
               AND ${statusNotIn(INBOX_HIDDEN_STATUSES, 'c.status')}
               ${triagedOnly ? `AND ${LOCAL_TRIAGED_SQL}` : ''}
               ${unreadOnly ? 'AND c.read = 0' : ''}
               AND c.key IN (
                 SELECT m.conversation_key FROM message_provider_state mps
                 JOIN messages m ON m.key = mps.message_key
                 WHERE mps.account_key = ?1
                   AND mps.folder_key = (
                     SELECT key FROM external_folders
                     WHERE account_key = ?1 AND well_known_role = '${FOLDER_ROLE.INBOX}' LIMIT 1
                   )
               )
             ORDER BY c.updated_at DESC LIMIT ?2 OFFSET ?3`,
            [acct.key, COLUMN_PAGE_SIZE, (page - 1) * COLUMN_PAGE_SIZE]
          );
          convs = rows.map(c => normalize(c, acct.key, acct.provider_type));
        }
        if (page === 1 && !subset) lastGoodRef.current[acct.key] = convs;
        return { ok: true, convs };
      } catch (e) {
        if (attempt < 3) {
          await new Promise(r => setTimeout(r, 400));
          continue;
        }
        log.warn('UnifiedInbox', `Failed to fetch from ${acct.key} (page ${page}): ${e?.message || e}`);
        return { ok: false, convs: page === 1 && !subset ? (lastGoodRef.current[acct.key] || []) : [] };
      }
    }
  }, [spaceFilter]);

  // Fetch all conversations
  const fetchAll = useCallback(async () => {
    if (accounts.length === 0) {
      setAllConversations([]);
      setLoading(false);
      return;
    }
    // Coalesce overlapping runs into a single trailing re-run.
    if (inFlightRef.current) { rerunRef.current = true; return; }
    inFlightRef.current = true;

    // Only show the full-screen loading state on the first load. Subsequent
    // refreshes revalidate in the background without blanking the list.
    if (!loadedOnceRef.current) setLoading(true);
    setError(null);

    try {
      // Drop columns of accounts that no longer exist.
      const keys = new Set(accounts.map(a => a.key));
      setAllConversations(prev => prev.filter(c => keys.has(c.accountKey)));

      // Each account merges into the stream as soon as it lands, so one slow
      // account (a big MX domain) no longer blocks the other columns. A failed
      // account simply leaves its previous column in place.
      const t0 = performance.now();
      const firstLoad = !loadedOnceRef.current;
      const settled = await Promise.all(accounts.map(async (acct) => {
        // The column's first page, plus its triaged threads. The two are
        // separate queries because they answer different questions: the stream
        // wants the newest N, the matrix wants every triaged thread no matter
        // how far down it sits. Merged into one list — `conversations` filters
        // the triaged ones out of the stream, the matrix keeps only those.
        const owner = spaceOwners.has(acct.key);
        // Plus its unread threads, for the same reason: the badge counts every
        // unread in the inbox, so the unread view must show one that sits
        // below the first page too.
        const [res, triaged, unread] = await Promise.all([
          fetchAccount(acct, owner),
          fetchAccount(acct, owner, 1, { triagedOnly: true }),
          fetchAccount(acct, owner, 1, { unreadOnly: true }),
        ]);
        log.info('UnifiedInbox', `column ${acct.key} (${acct.provider_type}) landed in ${Math.round(performance.now() - t0)}ms — ${res.convs.length} convs (+${triaged.convs.length} triaged), ok=${res.ok}`);
        if (res.ok) {
          if (firstLoad && !loadedOnceRef.current) {
            log.info('UnifiedInbox', `first column cleared global loading after ${Math.round(performance.now() - t0)}ms (${acct.key})`);
          }
          // The stream half is always the column's first page. If the user has
          // scrolled it deeper, refresh that head and keep the pages below — the
          // unified inbox reloads itself on sync, new mail and focus, and
          // replacing the column would throw away everything they scrolled in.
          const depth = columnState(acct.key);
          if (depth.page <= 1) depth.ended = res.convs.length < COLUMN_PAGE_SIZE;
          setAllConversations(prev => {
            const others = prev.filter(c => c.accountKey !== acct.key);
            const head = [...res.convs, ...triaged.convs, ...unread.convs];
            const seen = new Set(head.map(c => c.id));
            const column = depth.page > 1
              ? [...head, ...prev.filter(c => c.accountKey === acct.key && !seen.has(c.id))]
              : dedupeById(head);
            return [...others, ...dedupeById(column)]
              .sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at));
          });
          loadedOnceRef.current = true;
          setLoading(false);
        }
        return res;
      }));
      const anyOk = settled.some(s => s.ok);

      // First load where every account errored out (transient initial-sync
      // contention): keep the loading state and retry shortly rather than
      // flashing an empty inbox. A later sync refresh would also re-trigger.
      if (!anyOk && !loadedOnceRef.current) {
        setTimeout(() => fetchAllRef.current?.(), 800);
        return;
      }

      log.info('UnifiedInbox', `loaded ${settled.reduce((n, s) => n + s.convs.length, 0)} conversations across ${accounts.length} account(s) in ${Math.round(performance.now() - t0)}ms`);
      setLoading(false);
    } catch (e) {
      log.error('UnifiedInbox', `Fetch failed: ${e?.message || e}`);
      setError(e?.message || "Couldn't load your mail");
      setLoading(false);
    } finally {
      inFlightRef.current = false;
      if (rerunRef.current) {
        rerunRef.current = false;
        fetchAllRef.current?.();
      }
    }
  }, [accounts, fetchAccount, spaceOwners, columnState]);

  // Keep a stable ref to the latest fetchAll for self-rescheduling/coalescing.
  useEffect(() => { fetchAllRef.current = fetchAll; }, [fetchAll]);

  // Next page for ONE column (infinite scroll). Each column pages on its own, so
  // scrolling a busy lane doesn't drag every other channel's pages along with it.
  // Safe to call on every scroll event: it no-ops once the column has reached
  // its end or while its previous page is still in flight.
  const loadMoreColumn = useCallback(async (accountKey) => {
    const acct = accounts.find(a => a.key === accountKey);
    if (!acct) return;
    const depth = columnState(accountKey);
    if (depth.ended || depth.loading) return;
    depth.loading = true;
    try {
      const page = depth.page + 1;
      const res = await fetchAccount(acct, spaceOwners.has(accountKey), page);
      if (!res.ok) return;
      depth.page = page;
      // A short page is the end of the column. Offset paging over a list that
      // keeps moving also repeats rows across pages, so drop ids already held —
      // which is why a full page can still add nothing and the length alone
      // can't decide when to stop.
      if (res.convs.length < COLUMN_PAGE_SIZE) depth.ended = true;
      setAllConversations(prev => {
        const seen = new Set(prev.map(c => c.id));
        const fresh = res.convs.filter(c => !seen.has(c.id));
        if (fresh.length === 0) return prev;
        return [...prev, ...fresh]
          .sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at));
      });
    } finally {
      depth.loading = false;
    }
  }, [accounts, fetchAccount, spaceOwners, columnState]);

  // The grid view's stream is every column merged into one rail, so extending
  // its tail means asking each column for more (the ones already exhausted
  // no-op).
  const loadMoreAllColumns = useCallback(() => {
    for (const acct of accounts) loadMoreColumn(acct.key);
  }, [accounts, loadMoreColumn]);

  // Initial fetch
  useEffect(() => {
    if (fetchedRef.current) return;
    fetchedRef.current = true;
    fetchAll();
  }, [fetchAll]);

  // Re-fetch when an account is added/removed or the space drill changes.
  // Watch the space KEY as well as the slug: the spc_ key resolves async
  // (after the org's spaces list loads), and the MX side fetches nothing
  // until it's present — the key arriving must refire the fetch.
  //
  // A different query also starts every column back at the top. A plain refresh
  // (sync, new mail, focus) deliberately does NOT — that's what keeps a scrolled
  // column from collapsing under you.
  useEffect(() => {
    if (!fetchedRef.current) return;
    columnPagesRef.current = {};
    fetchAll();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accounts.length, spaceFilter?.slug, spaceFilter?.key]);

  // Reload as mail arrives. Shared throttled sync-event trigger (also used by
  // useInboxConversations); held in a ref so it never re-subscribes when
  // fetchAll changes. On web the sync bus is silent, so this is only the 30s
  // failsafe there; the realtime + focus paths below carry web MX new mail.
  useSyncRefresh(fetchAll);
  // Realtime: new MX mail lands over ActionCable (org stream) → reload now, even
  // with the tab focused. Focus fallback covers a dropped/suspended socket.
  useMailRefresh(fetchAll);
  useRefetchOnFocus(fetchAll);

  // Toggle a channel on/off
  const toggleChannel = useCallback((key) => {
    setDisabledChannels(prev => {
      const next = new Set(prev);
      if (next.has(key)) {
        next.delete(key);
      } else {
        next.add(key);
      }
      return next;
    });
  }, []);

  // Raw apply priority (optimistic update + sync), no undo recording.
  const runApplyPriority = useCallback(async (convId, accountKey, urgent, important) => {
    // Optimistic update — mark as triaged once explicitly assigned
    setAllConversations(prev =>
      prev.map(c =>
        c.id === convId
          ? { ...c, urgent, important, triaged: true, quadrant: getQuadrant(urgent, important) }
          : c
      )
    );

    // Sync to provider
    try {
      const acct = accounts.find(a => a.key === accountKey);
      if (!acct) return;

      if (acct.provider_type === 'inbox2') {
        // MX/org: use tag API (org-scoped — the column key is a domain id)
        const orgId = acct.orgSlug || acct.key;
        const conv = allConversations.find(c => c.id === convId) || { id: convId };
        await setMxPriorityTags(orgId, conv, { urgent, important });
      } else if (isTauri()) {
        // External: use provider setPriority
        const { setPriority } = await import('../lib/providers/index.js');
        await setPriority(accountKey, [convId], urgent, important);
      }
    } catch (e) {
      log.error('UnifiedInbox', `Priority sync failed: ${e?.message || e}`);
    }
  }, [accounts, allConversations]);

  // Raw remove priority (return to untriaged stream), no undo recording.
  const runRemovePriority = useCallback(async (convId, accountKey) => {
    // Optimistic update — back to untriaged
    setAllConversations(prev =>
      prev.map(c =>
        c.id === convId
          ? { ...c, urgent: false, important: false, triaged: false, quadrant: null }
          : c
      )
    );

    try {
      const acct = accounts.find(a => a.key === accountKey);
      if (!acct) return;

      if (acct.provider_type === 'inbox2') {
        // MX/org: remove Urgent + Important + Later tags (org-scoped)
        const orgId = acct.orgSlug || acct.key;
        const conv = allConversations.find(c => c.id === convId) || { id: convId };
        await clearMxPriorityTags(orgId, conv);
      } else if (isTauri()) {
        const { clearPriority } = await import('../lib/providers/index.js');
        await clearPriority(accountKey, [convId]);
      }
    } catch (e) {
      log.error('UnifiedInbox', `Remove priority failed: ${e?.message || e}`);
    }
  }, [accounts, allConversations]);

  // Restore the previous priority of a conversation (undo helper).
  const restorePriority = useCallback((convId, accountKey, prev) => {
    if (prev?.triaged) return runApplyPriority(convId, accountKey, prev.urgent, prev.important);
    return runRemovePriority(convId, accountKey);
  }, [runApplyPriority, runRemovePriority]);

  // Apply priority + record undo/redo.
  const applyPriority = useCallback(async (convId, accountKey, urgent, important, { record = true, batch = null } = {}) => {
    const before = allConversations.find(c => c.id === convId);
    const prev = before ? { urgent: before.urgent, important: before.important, triaged: before.triaged } : null;
    await runApplyPriority(convId, accountKey, urgent, important);
    if (!record) return;
    useUndoStore.getState().record({
      batch,
      description: `Moved to ${getQuadrant(urgent, important).label}`,
      batchDescription: (n) => `Moved ${n} conversations to ${getQuadrant(urgent, important).label}`,
      variant: 'triage',
      icon: getQuadrant(urgent, important).icon,
      key: convId,
      undo: () => restorePriority(convId, accountKey, prev),
      redo: () => runApplyPriority(convId, accountKey, urgent, important),
    });
  }, [allConversations, runApplyPriority, restorePriority]);

  // Remove priority + record undo/redo.
  const removePriority = useCallback(async (convId, accountKey, { record = true, batch = null } = {}) => {
    const before = allConversations.find(c => c.id === convId);
    const prev = before ? { urgent: before.urgent, important: before.important, triaged: before.triaged } : null;
    await runRemovePriority(convId, accountKey);
    if (!record) return;
    useUndoStore.getState().record({
      batch,
      description: 'Removed priority',
      batchDescription: (n) => `Removed priority from ${n} conversations`,
      variant: 'triage',
      icon: 'tag.slash',
      key: convId,
      undo: () => restorePriority(convId, accountKey, prev),
      redo: () => runRemovePriority(convId, accountKey),
    });
  }, [allConversations, runRemovePriority, restorePriority]);

  // Raw standard action (archive, trash, mark, etc.), no undo recording.
  const runConversationAction = useCallback(async (convId, accountKey, action) => {
    // Move the tab badge now. The truth is recounted by useChannelUnreadCounts
    // (a COUNT query / the API count endpoint); this is what makes the number
    // move on click, and any drift is reconciled by the next recount. Every row
    // here is in the inbox pool the badge counts — the unified view has no
    // spam/trash folders — so unreadDelta's `inInbox` default holds.
    const acting = convsRef.current.find(c => c.id === convId);
    if (acting) useUnreadStore.getState().adjust(accountKey, unreadDelta(action, !acting.read));

    // Optimistic: remove from list for archive/trash/spam
    if (REMOVAL_ACTIONS.includes(action)) {
      setAllConversations(prev => prev.filter(c => c.id !== convId));
    } else if (Object.values(REVERSE_VERB).includes(action)) {
      // Restored to the inbox: the row stays in the unified stream, only its
      // status changes — so the menu stops offering "Move to Inbox" on it.
      setAllConversations(prev =>
        prev.map(c => c.id === convId ? { ...c, status: CONV_STATUS.OPEN } : c)
      );
    } else if (action === CONV_ACTION.MARK_READ) {
      setAllConversations(prev =>
        prev.map(c => c.id === convId ? { ...c, read: true } : c)
      );
    } else if (action === CONV_ACTION.MARK_UNREAD) {
      setAllConversations(prev =>
        prev.map(c => c.id === convId ? { ...c, read: false } : c)
      );
    }

    const acct = accounts.find(a => a.key === accountKey);
    if (!acct) return false;

    // Resolves to whether the provider took it (Lore's panel unhides a refused row).
    if (acct.provider_type === 'inbox2') {
      // The org API only exposes archive/trash/spam as member routes — read
      // state and the un-* restore verbs live on conversations#bulk. Posting
      // mark_read to a member route 404'd, so the optimistic update was
      // reverted and the reading pane re-marked the same thread forever.
      const verb = Object.values(REVERSE_VERB).includes(action) ? CONV_STATUS.OPEN : action;
      // Queued-for-retry counts as applied — the optimistic row stands and
      // the engine's MX queue lands it. Only an outright refusal reverts, by refetching.
      const ok = await commitAction(verb, () => api.bulkConversations(acct.orgSlug || acct.key, [convId], verb));
      if (!ok) fetchAll();
      return ok;
    } else if (isTauri()) {
      const { performAction } = await import('../lib/providers/index.js');
      return performAction(accountKey, [convId], action)
        .then(() => true)
        .catch(e => {
          log.error('UnifiedInbox', `Action ${action} failed: ${e?.message || e}`);
          fetchAll(); // undo the optimistic row/read change: the provider never took it
          return false;
        });
    }
    return false;
  }, [accounts, fetchAll]);

  // Lore auto mode filed a local thread as it was labelled (docs/Triage.md
  // "Auto mode"): take it off the columns, as an archive from here would.
  useEffect(() => syncManager.on('triage-updated', (payload) => {
    const key = payload?.conversationKey;
    if (key && payload.autoAction) setAllConversations(prev => prev.filter(c => c.key !== key));
  }), []);

  // Restore a removed conversation back to the inbox (undo of archive/trash/spam).
  const restoreConversation = useCallback(async (snapshot, accountKey, originalAction) => {
    const acct = accounts.find(a => a.key === accountKey);
    if (acct?.provider_type === 'inbox2') {
      // Refused: the thread is still in spam/trash, so don't put it back in the
      // list — commitAction has already told the user why.
      if (!await commitAction(CONV_STATUS.OPEN,
        () => api.bulkConversations(acct.orgSlug || acct.key, [snapshot.conv.id], CONV_STATUS.OPEN))) return;
    } else if (isTauri()) {
      const { performAction } = await import('../lib/providers/index.js');
      await performAction(accountKey, [snapshot.conv.id], REVERSE_VERB[originalAction])
        .catch(e => log.error('UnifiedInbox', `Restore failed: ${e?.message || e}`));
    }
    setAllConversations(prev => {
      if (prev.some(c => c.id === snapshot.conv.id)) return prev;
      const next = [...prev];
      next.splice(Math.min(snapshot.index, next.length), 0, snapshot.conv);
      return next;
    });
    // Back in the pool the badge counts (inInbox=false: it was filed until now).
    useUnreadStore.getState().adjust(
      accountKey, unreadDelta(REVERSE_VERB[originalAction], !snapshot.conv.read, false));
  }, [accounts]);

  // Perform a standard action + record undo/redo.
  const performConversationAction = useCallback(async (convId, accountKey, action, { record = true, batch = null } = {}) => {
    // "Move to Inbox" is a UI-level action, not a provider verb — resolve it to the
    // un-* verb matching the row's current status before dispatching (the org path
    // maps those to 'open'). Without this the raw 'move_to_inbox' string reached the
    // provider and the restore silently no-op'd. Mirrors useConversationActions +
    // SearchResultsView, which both resolve it.
    if (action === CONV_ACTION.MOVE_TO_INBOX) {
      const conv = allConversations.find(c => c.id === convId);
      const forward = STATUS_FORWARD_ACTION[conv?.status];
      const reverse = REVERSE_VERB[forward];
      if (!reverse) return;
      await runConversationAction(convId, accountKey, reverse);
      if (!record) return;
      useUndoStore.getState().record({
        batch,
        description: `Moved "${conv?.subject || 'conversation'}" to Inbox`,
        batchDescription: (n) => `Moved ${n} conversations to Inbox`,
        icon: 'tray.and.arrow.down',
        key: convId,
        undo: () => runConversationAction(convId, accountKey, forward),
        redo: () => runConversationAction(convId, accountKey, reverse),
      });
      return;
    }

    const isRemoval = REMOVAL_ACTIONS.includes(action);
    const index = isRemoval ? allConversations.findIndex(c => c.id === convId) : -1;
    const snapshot = index >= 0 ? { conv: allConversations[index], index } : null;

    const ok = await runConversationAction(convId, accountKey, action);

    // Refused: nothing happened, so there is nothing to undo.
    if (!record || !ok) return ok;

    if (isRemoval) {
      const verb = REMOVAL_PAST_TENSE[action];
      // Always surface a toast for a removal — even if the conversation wasn't
      // found in the in-memory list (e.g. archived straight from a deep-linked
      // detail). With a snapshot we can re-insert it in place; without one we
      // fall back to the reverse verb so Undo still un-files it on the backend.
      useUndoStore.getState().record({
        batch,
        description: `${verb} "${snapshot?.conv?.subject || 'conversation'}"`,
        batchDescription: (n) => `${verb} ${n} conversations`,
        variant: action === CONV_ACTION.TRASH ? 'danger' : 'triage',
        icon: ACTION_ICON[action],
        key: convId,
        undo: async () => {
          if (snapshot) await restoreConversation(snapshot, accountKey, action);
          else await runConversationAction(convId, accountKey, REVERSE_VERB[action]);
          onRestoreSelectRef.current?.(convId);
        },
        redo: () => runConversationAction(convId, accountKey, action),
      });
    } else if (action === CONV_ACTION.MARK_READ || action === CONV_ACTION.MARK_UNREAD) {
      const opposite = action === CONV_ACTION.MARK_READ ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ;
      useUndoStore.getState().record({
        batch,
        description: action === CONV_ACTION.MARK_READ ? 'Marked as read' : 'Marked as unread',
        batchDescription: (n) => `Marked ${n} conversations as ${action === CONV_ACTION.MARK_READ ? 'read' : 'unread'}`,
        icon: ACTION_ICON[action],
        key: convId,
        undo: () => runConversationAction(convId, accountKey, opposite),
        redo: () => runConversationAction(convId, accountKey, action),
      });
    }
    return ok;
  }, [allConversations, runConversationAction, restoreConversation]);

  // Channel-filtered conversations (shared base for stream + counts)
  const channelFiltered = useMemo(() => {
    const enabledKeys = new Set(
      Object.entries(channelStates)
        .filter(([, state]) => state.enabled)
        .map(([key]) => key)
    );
    if (enabledKeys.size < accounts.length) {
      return allConversations.filter(c => enabledKeys.has(c.accountKey));
    }
    return allConversations;
  }, [allConversations, channelStates, accounts.length]);

  // Apply priority filter for the stream
  // Default (no filter): hide triaged conversations — they're in the matrix
  const conversations = useMemo(() => {
    if (!priorityFilter) return channelFiltered.filter(c => !c.triaged);
    return channelFiltered.filter(c =>
      c.urgent === priorityFilter.urgent &&
      c.important === priorityFilter.important
    );
  }, [channelFiltered, priorityFilter]);

  // Priority counts — single pass
  const priorityCounts = useMemo(() => {
    const counts = { priority: 0, schedule: 0, delegate: 0, later: 0 };
    for (const c of channelFiltered) {
      if (c.urgent && c.important) counts.priority++;
      else if (!c.urgent && c.important) counts.schedule++;
      else if (c.urgent && !c.important) counts.delegate++;
      else counts.later++;
    }
    return counts;
  }, [channelFiltered]);

  return {
    conversations,
    allConversations,
    channelStates,
    toggleChannel,
    priorityFilter,
    setPriorityFilter,
    applyPriority,
    removePriority,
    performConversationAction,
    priorityCounts,
    accounts,
    loading,
    error,
    refetch: fetchAll,
    loadMoreColumn,
    loadMoreAllColumns,
  };
}
