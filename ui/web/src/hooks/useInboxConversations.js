import { getDb } from '../lib/db.js';
import { CONV_STATUS, INBOX_HIDDEN_STATUSES, DISCARDED_STATUSES, statusNotIn, statusFolderLabel } from '../lib/conversationStatus.js';
import { FOLDER_ROLE } from '../lib/folderRoles.js';
import { loadConversationFromDb, mapAttachments } from '../lib/conversationDetail.js';
import formatBytes from '../lib/formatBytes.js';
import { useState, useEffect, useMemo, useRef, useCallback } from 'react';
import useNavigationStore from '../stores/navigationStore';
import { isTauri } from '../lib/tauri';
import api from '../lib/localFirstApi';
import useSyncRefresh from './useSyncRefresh';
import useMailRefresh from './useMailRefresh';
import useRefetchOnFocus from './useRefetchOnFocus';
import syncManager from '../lib/sync-manager';
import log from '../lib/log';
import { CONVERSATION_PATCHED } from '../lib/triage';

// Remembers each channel's last selected conversation so cycling between
// channels (ChromeBar tabs, ⌘[ / ⌘], sidebar) restores where you left off.
// Module-level so it survives the route remount that account switching causes.
// Keyed by channel key: orgId for org/unified channels, accountKey for externals.
const channelSelections = {};

// Stable identity for the masked (channel-switching) list — a fresh [] each
// render would invalidate every downstream useMemo.
const NO_CONVERSATIONS = [];

// Rows per MX page. The API's own default is 25 (max 100) — a screen and a half
// of mail, so scrolling would fetch constantly. Pages beyond the first are
// appended as the user scrolls (loadMoreConversations).
const ORG_PAGE_SIZE = 50;

/**
 * Owns the inbox conversation data layer for both channel types:
 *  - external accounts → SQLite (+ background provider enrichment)
 *  - org/unified accounts → Rails API
 *
 * Handles the conversation list load, the selected-conversation detail load,
 * new-mail ping detection, and per-channel last-selected memory (auto-selecting
 * the first conversation when nothing valid is selected for the active folder).
 *
 * Returns the conversation state plus setters so callers (selection handlers,
 * conversation actions, keyboard nav, account-removal cleanup) can mutate it.
 */
export default function useInboxConversations({
  activeAccountKey, activeAccountProvider, orgId, activeView, mailboxFilter, senderFilter, textFilter,
  selectedId, syncStatus, selectedTags, spaceFilter, domainFilter,
  // The desktop reading pane opens a conversation as soon as a folder loads. The
  // phone shell (src/mobile/) shows the list first, so it turns this off.
  autoSelect = true,
}) {
  const [conversations, setConversations] = useState([]);
  const [selectedConv, setSelectedConv] = useState(null);
  const [enrichingKeys, setEnrichingKeys] = useState(new Set());
  // Surfaced when the MX conversation-list fetch fails, so the page can show an
  // error/retry affordance instead of a silently-empty inbox (the primary path).
  const [loadError, setLoadError] = useState(null);
  // Bumped by retry() to re-run the list effect after a failed load.
  const [retryNonce, setRetryNonce] = useState(0);
  const retry = useCallback(() => setRetryNonce((n) => n + 1), []);

  // MX list paging: how deep we've scrolled, and how big the folder actually is
  // (the API reports the unpaginated total in meta).
  const orgPageRef = useRef(1);
  const [orgTotal, setOrgTotal] = useState(0);
  // Set when a page comes back short — the definitive end of the folder. The
  // count alone can't terminate the scroll: pages are offsets into a list that
  // keeps moving, so repeats get deduped away and the loaded length can stay
  // below `total` forever, asking for one more page at every scroll.
  // Only ever set from a response handler (never an effect): a fresh query's own
  // first page corrects it on arrival, and until then the list is still loading.
  const [orgEnded, setOrgEnded] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const loadingMoreRef = useRef(false);

  // Auto-refresh the org (MX) list. Unlike external accounts (engine sync events,
  // handled below), the org list only re-runs its effect on dep/nonce changes —
  // on web the sync bus is silent, so new MX mail wouldn't appear until the user
  // changed folders. Reload it on realtime new-mail (ActionCable org stream), tab
  // refocus, and a 30s failsafe. Guarded to the org view (external accounts have
  // their own refresh path), and reloadOrgList → retry() re-runs the list fetch.
  const reloadOrgList = useCallback(() => {
    if (orgId && !activeAccountKey) retry();
  }, [orgId, activeAccountKey, retry]);
  useMailRefresh(reloadOrgList);
  useRefetchOnFocus(reloadOrgList);
  useSyncRefresh(reloadOrgList);

  // Tracks which channel the loaded `conversations` belong to, so we don't
  // record a stale selection during the window after the channel changed but
  // before its conversations have reloaded. Mirrored into state so the page can
  // render a loader for that window instead of the previous channel's mail.
  const loadedForChannelRef = useRef(null);
  const [loadedChannel, setLoadedChannel] = useState(null);
  const markLoaded = useCallback((channel) => {
    loadedForChannelRef.current = channel;
    setLoadedChannel(channel);
  }, []);

  // The MX org pool can be viewed as a whole (unified) or narrowed to one of the
  // org's domains via the per-domain workspace tab. A domain view is still the
  // org (Rails) channel, so it keys selection memory on orgId:domainKey — each
  // domain tab restores its own last-selected thread.
  const orgChannel = domainFilter ? `${orgId}:${domainFilter}` : orgId;
  const currentChannel = activeAccountKey || orgChannel;

  // Sequence guards: loads are triggered from two places (input changes and
  // sync alerts), so a per-effect cancelled flag isn't enough — a slow load
  // must not overwrite a newer one. Only the latest sequence applies its result.
  const listSeqRef = useRef(0);
  const detailSeqRef = useRef(0);

  // Coalesce overlapping list loads. A single channel switch changes
  // activeAccountKey AND activeView (and may reset the filter), and sync alerts
  // fire too — so loadExternalConversations was invoked several times in the
  // same tick, each running a concurrent SQLite query that contended with the
  // others (and the engine's writes), turning a ~15ms read into seconds. With an
  // in-flight guard, extra triggers set a "rerun" flag instead of launching a
  // parallel query; one trailing reload runs after the current one settles.
  const listInFlightRef = useRef(false);
  const listRerunRef = useRef(false);
  const loadFnRef = useRef(null);

  // ── Record the active selection as this channel's last-selected ──
  useEffect(() => {
    if (currentChannel && selectedId
        && loadedForChannelRef.current === currentChannel
        && conversations.some(c => c.id === selectedId)) {
      channelSelections[currentChannel] = selectedId;
    }
  }, [currentChannel, selectedId, conversations]);

  // ── Load conversations: external accounts (SQLite) ──
  const loadExternalConversations = useCallback(async () => {
    if (!activeAccountKey || !isTauri()) return;
    // Coalesce: if a load is already running, mark a trailing rerun and bail
    // rather than launching a concurrent (contending) query.
    if (listInFlightRef.current) { listRerunRef.current = true; return; }
    listInFlightRef.current = true;
    const seq = ++listSeqRef.current;
    const fresh = () => listSeqRef.current === seq;
    // Read the live selection from the store instead of depending on the
    // `selectedId` prop. The list content depends only on account/view/filter,
    // so a pure selection change must NOT reload it — reloading on selection is
    // what made a just-deleted thread flicker back: the post-delete navigate
    // re-queried SQLite before the trash write-back committed, so the row came
    // back as 'open' until the next sync (the "lingers a second then vanishes"
    // delay). Auto-select below still uses the current value.
    const selectedId = useNavigationStore.getState().conversationId;
    // const _t0 = performance.now(); // PERF: inbox-load timing (see git history) — re-enable to profile
    try {
      const db = await getDb();
      // log.info('PERF', `list getDb: ${Math.round(performance.now() - _t0)}ms (account=${activeAccountKey})`);
      // DB not ready yet (boot race with the Rust engine opening/migrating it).
      // Leave the current list untouched rather than painting an empty inbox —
      // the next trigger (sync alert, failsafe, folder switch) reloads once the
      // handle is available. getDb already retries the load internally.
      if (!db) { if (fresh()) log.warn('ConvLoad', 'DB not ready; skipping load'); return; }

      // Build query from active view filters
      const labelFilter = activeView?.filters?.find(f => f.field === 'gmail_label');
      const statusFilter = activeView?.filters?.find(f => f.field === 'status')?.value;
      // Meta channel sub-views narrow by surface (channel) and/or event kind —
      // e.g. a Messenger account's "Comments" view is channel=facebook, an
      // Instagram account's "Mentions" view is kind=mention.
      const channelFilter = activeView?.filters?.find(f => f.field === 'channel')?.value;
      const kindFilter = activeView?.filters?.find(f => f.field === 'kind')?.value;

      // Gmail-style search: typing in the Filter box while on the Inbox searches
      // ALL folders (not just the inbox), so an archived hit surfaces. Detected as
      // the inbox folder view + an active query → fall through to the unscoped
      // (no folder/label join) branch below. Results then get a folder badge so
      // you can see the ones that aren't in the inbox.
      const searchAllFolders =
        !!textFilter && labelFilter?.wellKnownRole === FOLDER_ROLE.INBOX;

      // NFC: the store writes normalized text (sync/util.rs `nfc`), and a query
      // typed or pasted on macOS can arrive decomposed — "أ" as alef + combining
      // hamza matches nothing against the precomposed form senders transmit.
      const q = textFilter ? textFilter.normalize('NFC') : textFilter;

      let rows;
      // Fast inbox path: the inbox is the slow case (it's the default view on
      // every channel switch). Every inbox message reliably carries an mps row
      // whose folder_key is the inbox folder (verified across Gmail/MS/IMAP — the
      // labels-LIKE alternative finds nothing folder_key doesn't), so we DRIVE
      // from the indexed (account_key, folder_key) set instead of scanning every
      // conversation in the account and running an unindexable labels-LIKE per
      // row. For an account with 34k conversations but 8 in the inbox this is the
      // difference between walking 34k rows (~2s cold) and reading ~8 (~5ms).
      // Restricted to the inbox role: custom-label folders have no folder_key
      // rows, so they must keep the labels-LIKE query below.
      // Must still hide ARCHIVED: an archive sets status locally at once, but the
      // inbox mps row lingers until the next provider sync drops it — folder
      // membership alone let the thread reappear for up to a sync cycle.
      if (labelFilter && !searchAllFolders && labelFilter.wellKnownRole === FOLDER_ROLE.INBOX) {
        const folderKey = labelFilter.folderKey || labelFilter.value;
        const qparams = [activeAccountKey, folderKey];
        let textClause = '';
        if (textFilter) {
          textClause = ' AND (c.from_address LIKE ?3 OR c.to_address LIKE ?3 OR c.subject LIKE ?3'
            + ' OR EXISTS (SELECT 1 FROM messages mf WHERE mf.conversation_key = c.key AND mf.attachment_names LIKE ?3))';
          qparams.push(`%${q}%`);
        }
        rows = await db.select(
          `SELECT c.key as id, c.key, c.subject, c.from_address, c.to_address,
                  c.status, c.snippet, c.read, c.has_attachment, c.priority_urgent, c.priority_important, c.created_at, c.updated_at,
                  c.triage_label, c.triage_priority, c.ai_summary_short, c.channel, c.kind, c.from_avatar,
                  (SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = c.key) AS message_count
           FROM conversations c
           WHERE c.organization_id = ?1
             AND c.key IN (
               SELECT m.conversation_key FROM message_provider_state mps
               JOIN messages m ON m.key = mps.message_key
               WHERE mps.account_key = ?1 AND mps.folder_key = ?2
             )
             AND ${statusNotIn(INBOX_HIDDEN_STATUSES, 'c.status')}${textClause}
           ORDER BY c.updated_at DESC LIMIT 200`,
          qparams
        );
      } else if (labelFilter && !searchAllFolders) {
        const label = labelFilter.value;
        const folderKey = labelFilter.folderKey || label;
        // Well-known folders (Sent/Drafts) hold mail that is intentionally not
        // in the inbox — which our status model records as "archived" — so they
        // must NOT exclude archived, or they show empty. User-label views still
        // hide archived (a thread you archived shouldn't resurface under its
        // label — see f0eec23). Both always drop trash/spam.
        const labelStatuses = labelFilter.wellKnownRole ? DISCARDED_STATUSES : INBOX_HIDDEN_STATUSES;
        // Filter-field text searches from/to/subject within the folder (one
        // bound param reused across all three columns).
        const qparams = [activeAccountKey, `%"${label}"%`, folderKey];
        let textClause = '';
        if (textFilter) {
          textClause = ' AND (c.from_address LIKE ?4 OR c.to_address LIKE ?4 OR c.subject LIKE ?4 OR m.attachment_names LIKE ?4)';
          qparams.push(`%${q}%`);
        }
        rows = await db.select(
          `SELECT DISTINCT c.key as id, c.key, c.subject, c.from_address, c.to_address,
                  c.status, c.snippet, c.read, c.has_attachment, c.priority_urgent, c.priority_important, c.created_at, c.updated_at,
                  c.triage_label, c.triage_priority, c.ai_summary_short, c.channel, c.kind, c.from_avatar,
                  (SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = c.key) AS message_count,
                  (SELECT MAX(mo.created_at) FROM messages mo
                     JOIN message_provider_state mpo ON mpo.message_key = mo.key
                     JOIN external_folders fo ON fo.key = mpo.folder_key
                     WHERE mo.conversation_key = c.key AND fo.well_known_role = 'sent') AS sent_at
           FROM conversations c
           JOIN messages m ON m.conversation_key = c.key
           JOIN message_provider_state mps ON mps.message_key = m.key
           WHERE c.organization_id = ?1
             AND (mps.labels LIKE ?2 OR mps.folder_key = ?3)
             AND ${statusNotIn(labelStatuses, 'c.status')}${textClause}
           ORDER BY c.updated_at DESC LIMIT 200`,
          qparams
        );
      } else {
        // Status filter, text search, or unfiltered — all use the same base query.
        const conditions = ['organization_id = ?1'];
        const params = [activeAccountKey];
        // Meta channel/kind narrows (dynamic param indices so they compose with
        // the status/text clauses below).
        if (channelFilter) {
          conditions.push(`channel = ?${params.length + 1}`);
          params.push(channelFilter);
        }
        if (kindFilter) {
          conditions.push(`kind = ?${params.length + 1}`);
          params.push(kindFilter);
        }
        if (statusFilter) {
          conditions.push(`status = ?${params.length + 1}`);
          params.push(statusFilter);
        } else if (textFilter) {
          // Searching (incl. the Explorer / "view sender" drill-down, which seeds
          // the field): show ALL matching mail including archived — the
          // relationship graph counts archived threads (DISCARDED_STATUSES), so a
          // contact whose mail is archived must still appear. Only trash/spam hide.
          conditions.push(statusNotIn(DISCARDED_STATUSES));
        } else {
          conditions.push(statusNotIn(INBOX_HIDDEN_STATUSES));
        }
        // The Filter field is a real search over from/to/subject/attachment-name
        // across the whole folder (one bound param reused), not a client-side
        // narrow of loaded rows — so editing it re-queries instead of filtering a
        // person-locked set. attachment_names lives on messages, hence the EXISTS.
        if (textFilter) {
          const p = params.length + 1;
          conditions.push(
            `(from_address LIKE ?${p} OR to_address LIKE ?${p} OR subject LIKE ?${p} ` +
            `OR EXISTS (SELECT 1 FROM messages mf WHERE mf.conversation_key = conversations.key AND mf.attachment_names LIKE ?${p}))`
          );
          params.push(`%${q}%`);
        }
        rows = await db.select(
          `SELECT key as id, key, subject, from_address, to_address, status, snippet, read, has_attachment,
                  priority_urgent, priority_important, created_at, updated_at,
                  triage_label, triage_priority, ai_summary_short, channel, kind, from_avatar,
                  (SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = conversations.key) AS message_count
           FROM conversations WHERE ${conditions.join(' AND ')}
           ORDER BY updated_at DESC LIMIT 200`,
          params
        );
      }
      // log.info('PERF', `list query: ${Math.round(performance.now() - _t0)}ms (rows=${rows.length}, view=${activeView?.name || 'Inbox'})`);
      if (!fresh()) return;
      // Cross-folder search: tag each hit with the folder it lives in (Archive/
      // Spam/Trash) so non-inbox results are visibly labelled, like Gmail. Inbox
      // (open) hits get no badge. Only when searching all folders — a scoped
      // folder view already tells you where you are.
      if (searchAllFolders) {
        rows = rows.map(r => ({ ...r, searchFolder: statusFolderLabel(r.status) }));
      }
      // Stamp the account's provider so the list/detail render path can branch
      // social-vs-email per row (the list rows are otherwise raw SQLite). MX/org
      // rows come from the API path below and are never social.
      if (activeAccountProvider) {
        rows = rows.map(r => ({ ...r, providerType: activeAccountProvider }));
      }
      log.info('ConvLoad', `loaded ${rows.length} conversations (account=${activeAccountKey} view=${activeView?.name || 'Inbox'})`);
      // Was this channel already showing before this load? If so, an empty
      // selection is the user's choice (they pressed Escape to view the
      // empty-state game), not a fresh channel entry — so a sync refresh must
      // not auto-select a conversation and yank them out of it.
      const channelAlreadyLoaded = loadedForChannelRef.current === activeAccountKey;
      setConversations(rows);
      markLoaded(activeAccountKey);
      // When nothing valid is selected for this folder (no selection, or a
      // stale id carried over from another channel/folder), restore this
      // channel's last-selected conversation if it's present, else the first.
      if (!selectedId || !rows.some(r => r.id === selectedId)) {
        // selectedId may be valid for THIS account yet absent from the current
        // filtered view — e.g. opened from a notification while a narrower
        // view/folder is active. Don't clobber it: only fall back to a default
        // when the id is genuinely stale (doesn't belong to this account). The
        // detail-load below opens the thread by key regardless of view.
        let ownedByAccount = false;
        if (selectedId) {
          try {
            const owned = await db.select(
              'SELECT 1 FROM conversations WHERE key = ?1 AND organization_id = ?2 LIMIT 1',
              [selectedId, activeAccountKey]
            );
            ownedByAccount = owned.length > 0;
          } catch { /* treat as not owned → restore default below */ }
        }
        if (!fresh()) return;
        // Don't auto-select on a same-channel sync refresh when the user has
        // deliberately deselected (no id at all) — that's how they reach the
        // empty reading pane / game and a sync mustn't pull them back into the
        // last thread. Genuine channel entry (channelAlreadyLoaded === false)
        // and stale cross-channel ids still get a default.
        const userDeselectedHere = !selectedId && channelAlreadyLoaded;
        if (!ownedByAccount && !userDeselectedHere) {
          const remembered = channelSelections[activeAccountKey];
          const target = remembered && rows.some(r => r.id === remembered) ? remembered : rows[0]?.id;
          if (target) {
            useNavigationStore.getState().navigateTo({ conversationId: target }, { replace: true, replaceStack: true });
          } else {
            setSelectedConv(null);
          }
        }
      }
    } catch (e) {
      if (fresh()) {
        log.warn('ConvLoad', `SQLite load failed: ${e?.message || e}`);
        setConversations([]);
        markLoaded(activeAccountKey); // don't leave the loader spinning forever
      }
    } finally {
      listInFlightRef.current = false;
      // One trailing reload if anything asked to reload while we were busy.
      if (listRerunRef.current) { listRerunRef.current = false; loadFnRef.current?.(); }
    }
  }, [activeAccountKey, activeAccountProvider, activeView, textFilter, markLoaded]);

  // Keep loadFnRef pointed at the latest closure so the coalesced trailing
  // rerun (in the finally above) calls the current one. Ref-only — no setState.
  useEffect(() => { loadFnRef.current = loadExternalConversations; }, [loadExternalConversations]);

  // Reload on input changes (account / view / filter). NOT on selection — see
  // the live-selectedId read above.
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { loadExternalConversations(); }, [loadExternalConversations]);

  // Reload when the engine alerts that THIS account changed (push, not polled).
  useSyncRefresh((alert) => {
    if (!activeAccountKey) return;
    if (!alert || alert.accountKeys.has(activeAccountKey)) loadExternalConversations();
  });

  // Live triage label updates (background worker drain, or the dev-mode
  // re-classify action): patch the affected row and the open detail in place —
  // no full reload, the engine already wrote SQLite.
  useEffect(() => {
    const off = syncManager.on('triage-updated', (payload) => {
      const key = payload?.conversationKey;
      if (!key) return;
      // Lore auto mode filed it (archive/trash) as it was labelled: off the list.
      if (payload.autoAction) {
        setConversations(prev => prev.filter(c => c.key !== key));
        // The open thread was filed: close it rather than show a filed thread as current.
        setSelectedConv(prev => (prev && (prev.key === key || prev.id === key) ? null : prev));
        // …and drop it from the navigation selection, so no detail load reopens it.
        if (useNavigationStore.getState().conversationId === key) {
          useNavigationStore.getState().navigateTo({ conversationId: null }, { replace: true, replaceStack: true });
        }
        return;
      }
      // The generated one-liner rides on the event so the row's preview line
      // upgrades from body-snippet → summary in place (see conversationPreview).
      const patch = { triage_label: payload.label, triage_priority: payload.priority ?? null, ai_summary_short: payload.summaryShort };
      setConversations(prev =>
        prev.map(c => (c.key === key ? { ...c, ...patch } : c)));
      setSelectedConv(prev =>
        prev && (prev.key === key || prev.id === key) ? { ...prev, ...patch } : prev);
    });
    return () => off();
  }, []);

  // Manual triage on an MX row (useManualTriage): patch the row + open detail
  // with the conversation the API returned (label / Space) — no refetch.
  useEffect(() => {
    const onPatched = (e) => {
      const { id, patch } = e.detail || {};
      if (!id || !patch) return;
      const pick = { triage_label: patch.triage_label, triage_priority: patch.triage_priority, space: patch.space };
      setConversations(prev => prev.map(c => (c.id === id ? { ...c, ...pick } : c)));
      setSelectedConv(prev => (prev?.id === id ? { ...prev, ...pick } : prev));
    };
    document.addEventListener(CONVERSATION_PATCHED, onPatched);
    return () => document.removeEventListener(CONVERSATION_PATCHED, onPatched);
  }, []);

  // ── Load conversations: org accounts (Rails API) ──
  // The query for the current folder/filters, built once and shared by the first
  // page and every scrolled-in page — a later page filtered differently from the
  // first would silently mix folders together.
  const orgListParams = useMemo(() => {
    const params = { per_page: ORG_PAGE_SIZE };
    if (mailboxFilter) params.to = mailboxFilter;
    if (senderFilter) params.from = senderFilter;
    // Translate the active view's filters into API query params. Each system
    // view carries its own distinguishing filter (Sent=direction:outbound,
    // Drafts=is_draft:true, Unassigned=assignee:is_empty, Mentioned=mentioned:is_me);
    // without this every view collapsed to status=open and Inbox/Sent/Drafts all
    // showed the same list.
    //
    // The Inbox is special: it is the open *pool* (every member sees the whole
    // domain's open mail — see ConversationsController#unread_count), never an
    // assignee scope. We force status=open for it regardless of the filter it
    // ships with, because some backends still serve the legacy Inbox definition
    // (assignee:is_me, from when it was named "Assigned to me"); honoring that
    // would empty the inbox whenever nothing is assigned to the viewer.
    const isInbox = activeView?.kind === 'system' && activeView?.name === 'Inbox';
    if (isInbox) {
      params.status = CONV_STATUS.OPEN;
    } else {
      for (const f of (activeView?.filters || [])) {
        switch (f.field) {
          case 'status': params.status = f.value; break;
          case 'direction': params.direction = f.value; break;
          case 'is_draft': params.is_draft = f.value; break;
          case 'assignee':
            params.assignee = f.operator === 'is_me' ? 'me' : f.operator === 'is_empty' ? 'none' : f.value;
            break;
          case 'mentioned':
            if (f.operator === 'is_me') params.mentioned = 'me';
            break;
          default: break;
        }
      }
      // Default to the open pool when no folder-defining filter is set (e.g. a
      // not-yet-resolved view). "All Mail" intentionally has no filters, so it
      // must NOT be forced to open — it spans every status.
      const hasScopingFilter = params.status || params.direction || params.is_draft || params.assignee || params.mentioned;
      if (!hasScopingFilter && activeView?.name !== 'All Mail') params.status = CONV_STATUS.OPEN;
      if (activeView?.name === 'All Mail') params.include_sent = 'true';
    }
    // Sidebar LABELS overlay: AND the folder above with the selected tags
    // (OR among themselves). Sent as tags[] so the API filters server-side
    // (the list is paginated, so client-side narrowing would be wrong).
    const tagNames = selectedTags ? Array.from(selectedTags) : [];
    if (tagNames.length) params.tags = tagNames;
    // Space drill-down (treemap → inbox): narrow the open pool to one MX
    // classification bucket. AND-ed with the folder/labels above.
    if (spaceFilter) params.space = spaceFilter;
    // Per-domain workspace tab: narrow the org's MX pool to one domain.
    if (domainFilter) params.domain = domainFilter;
    return params;
  }, [mailboxFilter, senderFilter, activeView, selectedTags, spaceFilter, domainFilter]);

  // A new query (folder switch, filter change, another domain tab) starts at the
  // top. Declared before the load effect so the depth is already reset when that
  // load resolves — a refetch of the SAME query must keep the depth instead.
  useEffect(() => { orgPageRef.current = 1; }, [orgChannel, orgListParams]);

  useEffect(() => {
    if (activeAccountKey || !orgId) return;
    let cancelled = false;

    api.getConversations(orgId, orgListParams)
      .then(data => {
        if (cancelled) return;
        setLoadError(null);
        // Already showing this channel? Then an empty selection is deliberate
        // (Escape → empty-state game), so a sync-driven reload must not
        // auto-select and yank the user back into the last thread.
        const channelAlreadyLoaded = loadedForChannelRef.current === orgChannel;
        // This load is always page 1. If the user has scrolled deeper, refresh
        // the head and keep the pages below it — the org list reloads itself on
        // new mail, focus and a 30s failsafe, and replacing the whole list would
        // throw away everything they scrolled in (and jump them back to the top)
        // every time one of those fired.
        setConversations(prev => {
          if (orgPageRef.current <= 1) return data.conversations;
          const head = data.conversations;
          const ids = new Set(head.map(c => c.id));
          return [...head, ...prev.filter(c => !ids.has(c.id))];
        });
        setOrgTotal(data.meta?.total ?? data.conversations.length);
        if (orgPageRef.current <= 1) setOrgEnded(data.conversations.length < ORG_PAGE_SIZE);
        markLoaded(orgChannel);
        // When nothing valid is selected for this folder (no selection, or a
        // stale id carried over from another channel/folder), restore this
        // channel's last-selected conversation if it's present, else the first.
        const userDeselectedHere = !selectedId && channelAlreadyLoaded;
        if (autoSelect && !userDeselectedHere && data.conversations.length > 0 && (!selectedId || !data.conversations.some(c => c.id === selectedId))) {
          const remembered = channelSelections[orgChannel];
          const target = remembered && data.conversations.some(c => c.id === remembered)
            ? remembered : data.conversations[0].id;
          useNavigationStore.getState().navigateTo({ conversationId: target }, { replace: true, replaceStack: true });
        }
      })
      .catch((e) => { if (!cancelled) { setLoadError(e); markLoaded(orgChannel); } });
    return () => { cancelled = true; };
  }, [orgId, orgChannel, activeAccountKey, orgListParams, selectedId, syncStatus, retryNonce, markLoaded, autoSelect]);

  // More of this folder exists than is loaded. `orgTotal` is the API's
  // unpaginated count for the same query, so this doesn't have to guess from a
  // full last page; `orgEnded` stops it once a short page proves the tail.
  const orgHasMore = !activeAccountKey && !orgEnded && conversations.length < orgTotal;

  // Next page of the MX list, appended (infinite scroll). Without this the inbox
  // was one page and stopped: 25 threads, no way to reach the 26th — the pool
  // above it existed only in the unread count.
  const loadMoreConversations = useCallback(async () => {
    if (activeAccountKey || !orgId) return;          // externals read SQLite, not pages
    if (loadingMoreRef.current || !orgHasMore) return;
    loadingMoreRef.current = true;
    setLoadingMore(true);
    const page = orgPageRef.current + 1;
    try {
      const data = await api.getConversations(orgId, { ...orgListParams, page });
      const rows = data.conversations || [];
      orgPageRef.current = page;
      if (data.meta?.total != null) setOrgTotal(data.meta.total);
      // A short page is the tail. Offset paging over a list that keeps moving
      // (new mail arrives, threads get filed) also repeats rows across pages —
      // key on id and keep the copy already on screen.
      if (rows.length < ORG_PAGE_SIZE) setOrgEnded(true);
      setConversations(prev => {
        const seen = new Set(prev.map(c => c.id));
        return [...prev, ...rows.filter(c => !seen.has(c.id))];
      });
    } catch (e) {
      log.warn('ConvLoad', `Load-more failed (page ${page}): ${e?.message || e}`);
    } finally {
      loadingMoreRef.current = false;
      setLoadingMore(false);
    }
  }, [activeAccountKey, orgId, orgListParams, orgHasMore]);

  // ── Load selected conversation detail: external accounts (SQLite + enrich) ──
  // Enriched full bodies are cached per message key so a sync-driven reload
  // neither drops them nor re-fetches them from the provider — only
  // genuinely-new messages are enriched.
  const enrichCacheRef = useRef({ convId: null, byKey: new Map() });
  const loadExternalDetail = useCallback(async () => {
    if (!selectedId || !activeAccountKey || !isTauri()) return;
    const seq = ++detailSeqRef.current;
    const fresh = () => detailSeqRef.current === seq;
    // const _t0 = performance.now(); // PERF: detail-load timing — re-enable to profile
    try {
      {
        const base = await loadConversationFromDb(selectedId);
        // log.info('PERF', `detail loadFromDb: ${Math.round(performance.now() - _t0)}ms (conv=${selectedId})`);
        if (!base) log.warn('ConvLoad', `detail: conversation ${selectedId} not found in DB`);
        if (!fresh() || !base) return;
        const { conv, messages: msgs } = base;

        // Reset the enrichment cache when switching conversations.
        if (enrichCacheRef.current.convId !== conv.id) {
          enrichCacheRef.current = { convId: conv.id, byKey: new Map() };
        }
        const cache = enrichCacheRef.current.byKey;
        const applyCache = (list) => list.map(m => {
          const e = cache.get(m.key);
          return e
            ? { ...m, body_html: e.body_html || m.body_html, body_plain: e.body_plain || m.body_plain, attachments: e.attachments || m.attachments }
            : m;
        });
        setSelectedConv({ ...conv, providerType: activeAccountProvider, messages: applyCache(msgs) });

        // Enrich only messages not yet fetched (full bodies + inline images).
        const toEnrich = msgs.filter(m => !cache.has(m.key));
        if (toEnrich.length === 0) return;
        const { fetchMessage } = await import('../lib/providers/index.js');
        log.info('Enrich', `Enriching ${toEnrich.length} new message(s)`);
        // const _tEnrich = performance.now(); // PERF: enrichment timing — re-enable to profile
        setEnrichingKeys(new Set(toEnrich.map(m => m.key)));
        await Promise.all(
          toEnrich.map(async (msg) => {
            // const _tm = performance.now(); // PERF
            try {
              const result = await fetchMessage(activeAccountKey, msg.key);
              // log.info('PERF', `enrich fetchMessage: ${Math.round(performance.now() - _tm)}ms (msg=${msg.key})`);
              const atts = mapAttachments(result?.attachments, msg.key, formatBytes);
              cache.set(msg.key, {
                body_html: result?.body_html,
                body_plain: result?.body_plain,
                attachments: atts.length > 0 ? atts : undefined,
              });
            } catch (e) {
              log.error('Enrich', `FAILED ${msg.key}: ${e?.message || e}`);
              cache.set(msg.key, {}); // don't retry on every tick
            }
          })
        );
        // log.info('PERF', `enrich total: ${Math.round(performance.now() - _tEnrich)}ms (${toEnrich.length} msg)`);
        if (!fresh()) return;
        setEnrichingKeys(new Set());
        setSelectedConv(prev => prev?.id === conv.id ? { ...prev, messages: applyCache(prev.messages) } : prev);
      }
    } catch (e) {
      if (fresh()) log.warn('ConvLoad', `Failed to load conversation: ${e?.message || e}`);
    }
  }, [activeAccountKey, activeAccountProvider, selectedId]);

  // Reload the open thread on selection/account change.
  useEffect(() => { loadExternalDetail(); }, [loadExternalDetail]);

  // Reload the open thread when the engine alerts that ITS conversation changed
  // (fine-grained: ignores unrelated syncs, so no needless re-enrichment).
  useSyncRefresh((alert) => {
    if (!selectedId) return;
    if (!alert || alert.conversationKeys.has(selectedId)) loadExternalDetail();
  });

  // ── Load selected conversation detail: org accounts (Rails API) ──
  useEffect(() => {
    if (!selectedId || activeAccountKey || !orgId) return;
    let cancelled = false;
    api.getConversation(orgId, selectedId)
      .then(data => { if (!cancelled) setSelectedConv(data.conversation); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [orgId, activeAccountKey, selectedId]);

  // Between a channel switch and its first load, `conversations` still holds the
  // previous channel's mail — showing it under the new tab reads as a bug. Mask
  // it (and, via selectedConvInView, the open thread) until this channel's rows
  // land; the page renders a ghost list for that window.
  const listLoading = !!currentChannel && loadedChannel !== currentChannel;

  return {
    conversations: listLoading ? NO_CONVERSATIONS : conversations, setConversations,
    listLoading,
    selectedConv, setSelectedConv,
    enrichingKeys, setEnrichingKeys,
    loadError, retry,
    loadMoreConversations, hasMoreConversations: orgHasMore, loadingMore,
  };
}
