import { getDb } from '../../lib/db.js';
import useSelectedConversationDetail from '../../hooks/useSelectedConversationDetail';
import { useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { useParams, useNavigate, useSearchParams } from 'react-router';
import useAuth from '../../hooks/useAuth';
import useAccounts from '../../hooks/useAccounts';
import useNavigationStore from '../../stores/navigationStore';
import api from '../../lib/localFirstApi';
import { isTauri } from '../../lib/tauri';
import { invoke } from '@tauri-apps/api/core';
import { PROVIDER } from '../../lib/providerTypes';
import log from '../../lib/log';
import Icon from '../../components/Icon';
import ListViewColumns from '../../components/ListViewColumns/ListViewColumns';
import EmailPreviewPopup from '../../components/EmailPreviewPopup/EmailPreviewPopup';
import ConversationDetail from '../../components/ConversationDetail/ConversationDetail';
import WaChatPane from '../../components/WaChatPane/WaChatPane';
import { WA_LOCAL_KEY, useLocalWhatsAppEnabled, waSearch, waMediaUrl } from '../../lib/localWhatsApp';
import DotMatrix from '../../components/DotMatrix';
import MessageShortcuts from '../../components/MessageShortcuts';
import ShortcutsHelp from '../../components/ShortcutsHelp';
import UndoToast from '../../components/UndoToast/UndoToast';
import useShortcutHelp from '../../hooks/useShortcutHelp';
import useMarkRead from '../../hooks/useMarkRead';
import useHoverPreview from '../../hooks/useHoverPreview';
import useColumnSelection from '../../hooks/useColumnSelection';
import usePendingCompose from '../../hooks/usePendingCompose';
import ContextMenu from '../../components/DropdownMenu/ContextMenu';
import useUndoStore from '../../stores/undoStore';
import { normalize } from '../../hooks/useUnifiedInbox';
import { suggestLocalQuery } from '../../lib/searchSuggest';
import { CONV_ACTION, REMOVAL_ACTIONS, REVERSE_VERB, STATUS_FORWARD_ACTION, REMOVAL_PAST_TENSE, ACTION_ICON, conversationContextMenuItems, bulkActionMenuItems, commitAction, unreadDelta } from '../../lib/conversationActions';
import useManualTriage, { manualTriageTarget } from '../../hooks/useManualTriage';
import useUnreadStore from '../../stores/unreadStore';
import { CONV_STATUS, DISCARDED_STATUSES, statusNotIn } from '../../lib/conversationStatus';
// Trash and Spam stay out of results unless in:anywhere says otherwise (Gmail's
// rule) — a hit you just deleted coming straight back reads as "the delete
// didn't work". Archive still shows, badged by statusFolderLabel.
import { parse, format, isBare, toSqlite, toApiParams } from '../../lib/searchQuery';
import SearchFilterPopover from '../../components/SearchFilters/SearchFilterPopover';
import SearchFilterChips from '../../components/SearchFilters/SearchFilterChips';
import { getQuadrant, QUADRANTS } from '../../lib/priority';
import { setMxPriorityTags, clearMxPriorityTags } from '../../lib/mxPriority';
import { initialsDataUri } from '../../lib/initialsIcon';
import layoutStyles from '../../styles/layout.module.css';
import styles from './SearchResultsView.module.css';

/**
 * Build a SQLite FTS5 MATCH expression from a user query.
 * Mirrors Postgres `websearch_to_tsquery` semantics so both search
 * paths behave the same: bare terms are ANDed (FTS5 default), `or`
 * (case-insensitive) is the OR operator, and "quoted text" is a phrase.
 * Each term is quoted so FTS5 special characters can't break the query.
 * Leading/trailing/duplicate operators are dropped to keep MATCH valid.
 * Returns '' if the query reduces to nothing searchable.
 */
function buildFtsMatch(query) {
  const tokens = query.match(/-?"[^"]*"|\S+/g) || [];
  const parts = [];
  const excluded = [];
  for (const tok of tokens) {
    // `-word` / `-"a phrase"` excludes. Quoting it as a term instead would
    // REQUIRE the word (the tokenizer drops the dash) — the opposite.
    if (tok.length > 1 && tok.startsWith('-')) {
      const inner = tok.slice(1).replace(/"/g, '').trim();
      if (inner) excluded.push(`"${inner}"`);
      continue;
    }
    const upper = tok.toUpperCase();
    if (upper === 'OR' || upper === 'AND') {
      // Skip operators with no preceding term, or back-to-back operators.
      const prev = parts[parts.length - 1];
      if (!prev || prev === 'OR' || prev === 'AND') continue;
      parts.push(upper);
      continue;
    }
    const inner = (tok.startsWith('"') && tok.endsWith('"') ? tok.slice(1, -1) : tok)
      .replace(/"/g, '')
      .trim();
    if (inner) parts.push(`"${inner}"`);
  }
  // Drop any trailing operator left dangling.
  while (parts.length && (parts[parts.length - 1] === 'OR' || parts[parts.length - 1] === 'AND')) {
    parts.pop();
  }
  // FTS5 NOT is binary (`a NOT b`), so exclusions trail the bracketed rest — an
  // OR in it can't let excluded mail back in. Nothing to subtract from = no query.
  if (!parts.length) return '';
  return excluded.length ? `(${parts.join(' ')}) NOT ${excluded.join(' NOT ')}` : parts.join(' ');
}

/**
 * "Did you mean …?" over the local FTS5 index. Desktop only — in the browser
 * there are no local channels to draw a vocabulary from, and the API half of
 * the search brings its own suggestion.
 */
async function localSuggestion(query) {
  if (!isTauri()) return null;
  try {
    return await suggestLocalQuery(await getDb(), query);
  } catch (e) {
    log.warn('Search', `Suggestion lookup failed: ${e?.message || e}`);
    return null;
  }
}

/**
 * Search results from all connected accounts, presented in
 * per-channel columns (ListViewColumns) + detail, matching the
 * unified inbox list view layout.
 */
// Provider-side search (Gmail `q` / Graph `$search`) for the channels that have
// one, mapped back to local conversations by the Rust core. Only conversations
// not already in `seen` are loaded. A provider that fails (offline, quota) just
// adds nothing — the local results stand.
async function providerHits(accounts, text, seen) {
  const searchable = (accounts || []).filter(a => a.provider_type === PROVIDER.GMAIL || a.provider_type === PROVIDER.MICROSOFT);
  const perAccount = await Promise.all(searchable.map(async (acct) => {
    try {
      const keys = (await invoke('provider_search', { accountKey: acct.key, query: text })).filter(k => !seen.has(k));
      if (!keys.length) return [];
      const db = await getDb();
      const rows = await db.select(
        `SELECT c.key as id, c.key, c.subject, c.from_address, c.to_address,
                c.status, c.snippet, c.read, c.has_attachment,
                c.priority_urgent, c.priority_important,
                c.created_at, c.updated_at
         FROM conversations c
         WHERE c.organization_id = ?1 AND c.key IN (SELECT value FROM json_each(?2))
           AND ${statusNotIn(DISCARDED_STATUSES, 'c.status')}`,
        [acct.key, JSON.stringify(keys)]
      );
      return rows.map(row => normalize(row, acct.key, acct.provider_type));
    } catch (e) {
      log.warn('Search', `Provider search failed for ${acct.key}: ${e?.message || e}`);
      return [];
    }
  }));
  return perAccount.flat();
}

// Local WhatsApp hits (WhatsApp Desktop's database, read-only) as rows of their
// own column. They carry `waChat`/`waMsgId` and no mail actions: selecting one
// opens the chat at that message instead of a conversation detail.
async function whatsAppHits(text) {
  try {
    const hits = await waSearch(text);
    return hits.map(h => {
      const at = new Date(h.at).toISOString();
      const who = h.from_me ? 'You' : (h.sender || h.chat_name);
      return {
        id: `wa-${h.id}`,
        key: `wa-${h.id}`,
        accountKey: WA_LOCAL_KEY,
        providerType: PROVIDER.WHATSAPP,
        channel: PROVIDER.WHATSAPP,
        subject: h.chat_name,
        from_address: who,
        snippet: h.text,
        read: true,
        status: CONV_STATUS.OPEN,
        created_at: at,
        updated_at: at,
        tags: [],
        message_count: 1,
        from_avatar: waMediaUrl(h.chat_avatar),
        waChat: { id: h.chat_id, name: h.chat_name, avatar: h.chat_avatar, is_group: h.is_group },
        waMsgId: h.id,
      };
    });
  } catch (e) {
    log.warn('Search', `WhatsApp search failed: ${e?.message || e}`);
    return [];
  }
}

export default function SearchResultsView() {
  const { orgSlug } = useParams();
  const navigate = useNavigate();
  const [searchParams, setSearchParams] = useSearchParams();
  const initialQuery = searchParams.get('q') || '';

  // The whole query — words AND filters — lives in ?q= as one operator string
  // ("invoice from:ana larger:5mb"). The box and the Filters popover are two
  // editors of the object it parses to, so neither can drift from the results,
  // and a search stays a shareable, refreshable URL.
  const filter = useMemo(() => parse(initialQuery), [initialQuery]);
  const setFilter = useCallback((next) => {
    setSearchParams(prev => {
      const p = new URLSearchParams(prev);
      p.set('q', format(next));
      return p;
    });
  }, [setSearchParams]);
  const includeDiscarded = filter.in === 'anywhere';
  const toggleDiscarded = useCallback(
    () => setFilter({ ...filter, in: filter.in === 'anywhere' ? null : 'anywhere' }),
    [filter, setFilter]
  );
  const { user, organizations } = useAuth();
  const { externalAccounts } = useAccounts(organizations);
  const localWhatsApp = useLocalWhatsAppEnabled();

  const orgId = orgSlug;
  const currentOrg = organizations?.find(o => o.slug === orgSlug || o.id === orgSlug);
  const orgDefaultFrom = currentOrg?.domain ? `${user?.username}@${currentOrg.domain}` : '';

  const [results, setResults] = useState([]);
  const [suggestion, setSuggestion] = useState(null);
  const [loading, setLoading] = useState(false);
  const [selectedId, setSelectedId] = useState(null);
  const [selectedConv, setSelectedConv] = useState(null);

  // Reply/forward from search must come from the channel the selected
  // conversation belongs to, not the org domain (results span all channels).
  const defaultFrom =
    externalAccounts.find(a => a.key === selectedConv?.accountKey)?.email_address
    || orgDefaultFrom;
  const [enrichingKeys, setEnrichingKeys] = useState(new Set());
  const [filtersOpen, setFiltersOpen] = useState(false);
  const { helpOpen, setHelpOpen } = useShortcutHelp();
  const undoToasts = useUndoStore(s => s.toasts);
  const undoAction = useUndoStore(s => s.undo);
  const dismissUndo = useUndoStore(s => s.dismiss);

  // Build account list for ChromeBar + ListViewColumns. Results are keyed per
  // ORG (api.search spans all of an org's domains), so these can't be the
  // per-domain tabs useAccounts builds — but the icon must resolve the same way
  // there as here, or the column header and its empty state disagree.
  const accounts = useMemo(() => {
    const orgAccounts = (organizations || []).map(org => ({
      key: org.slug || org.id,
      display_name: org.name || org.slug,
      email_address: org.domain || org.slug,
      provider_type: 'inbox2',
      icon_url: org.icon_url || initialsDataUri(org.domain || org.name || org.slug),
      status: 'connected',
    }));
    const whatsApp = localWhatsApp
      ? [{ key: WA_LOCAL_KEY, display_name: 'WhatsApp', email_address: 'WhatsApp on this Mac', provider_type: PROVIDER.WHATSAPP, status: 'connected' }]
      : [];
    return [...orgAccounts, ...(externalAccounts || []), ...whatsApp];
  }, [organizations, externalAccounts, localWhatsApp]);

  // Only channels that actually matched get a column. An "All caught up" lane
  // for an account with no hits reads as a broken search, not as an answer.
  const channelStates = useMemo(() => {
    const hit = new Set(results.map(c => c.accountKey));
    const states = {};
    for (const acct of accounts) {
      if (hit.has(acct.key)) states[acct.key] = { enabled: true, account: acct };
    }
    return states;
  }, [accounts, results]);

  // Execute search across all sources. Runs overlap while organizations/
  // externalAccounts stream in on mount — the seq guard keeps a stale earlier
  // run (e.g. API-only, before external accounts loaded) from overwriting a
  // newer run's results after they've rendered.
  const searchSeq = useRef(0);
  // `filter` is the parsed query — free text plus whatever operators the box or
  // the Filters popover set. Both halves of the search read the same object.
  const executeSearch = useCallback(async (filter) => {
    const seq = ++searchSeq.current;
    const text = filter.text.trim();
    // Filters alone are a valid search ("every PDF over 5MB"), so only a fully
    // empty query short-circuits.
    if (!text && isBare(filter)) {
      setResults([]);
      setSuggestion(null);
      return;
    }
    setLoading(true);
    const allResults = [];
    const apiSuggestions = [];

    try {
      // Search all sources in parallel
      const fetches = [];

      // Org accounts via API
      for (const org of (organizations || [])) {
        fetches.push(
          api.search(org.id || org.slug, text, toApiParams(filter))
            .then(data => {
              if (data.suggestion) apiSuggestions.push(data.suggestion);
              return (data.conversations || []).map(c =>
                normalize(c, org.slug || org.id, 'inbox2', org.slug || org.id));
            })
            .catch((e) => { log.warn('Search', `API search failed for ${org.slug}: ${e?.message || e}`); return []; })
        );
      }

      // External accounts via SQLite FTS5 (Tauri only). With no free text there
      // is nothing to MATCH, so the FTS table drops out of the join and the
      // filters carry the query on their own.
      const ftsQuery = text ? buildFtsMatch(text) : '';
      if (isTauri() && externalAccounts?.length && (ftsQuery || !text)) {
        fetches.push(
          (async () => {
            try {
              const db = await getDb();
              const hits = [];
              for (const acct of externalAccounts) {
                // ?1 = account, ?2 = the FTS expression when there is one.
                const binds = ftsQuery ? [acct.key, ftsQuery] : [acct.key];
                const { where, params } = toSqlite(filter, binds.length + 1);
                const rows = await db.select(
                  `SELECT DISTINCT c.key as id, c.key, c.subject, c.from_address, c.to_address,
                          c.status, c.snippet, c.read, c.has_attachment,
                          c.priority_urgent, c.priority_important,
                          c.created_at, c.updated_at
                   FROM ${ftsQuery ? 'messages_fts fts JOIN messages m ON m.rowid = fts.rowid' : 'messages m'}
                   JOIN conversations c ON c.key = m.conversation_key
                   WHERE c.organization_id = ?1
                     ${ftsQuery ? 'AND messages_fts MATCH ?2' : ''}
                     ${where.map(w => `AND ${w}`).join('\n                     ')}
                   ORDER BY c.updated_at DESC LIMIT 50`,
                  [...binds, ...params]
                );
                for (const row of rows) {
                  hits.push(normalize(row, acct.key, acct.provider_type));
                }
              }
              return hits;
            } catch (e) {
              log.warn('Search', `SQLite FTS search failed: ${e?.message || e}`);
              return [];
            }
          })()
        );
      }

      // Local WhatsApp: plain words only — the mail operators mean nothing there.
      if (localWhatsApp && text && isBare(filter)) fetches.push(whatsAppHits(text));

      const results = await Promise.all(fetches);
      if (seq !== searchSeq.current) return; // stale run — a newer search owns the screen
      for (const batch of results) allResults.push(...batch);
      allResults.sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at));
      setResults(allResults);

      // Second pass: Gmail/Outlook search their own index, which reads inside
      // attachments (ours only has filenames) — a word that lives only in an
      // attached PDF hits there. Local results are already on screen; provider
      // hits are appended. Plain text only: our filter operators aren't theirs.
      // Exclusions alone (-word) name nothing to look for: the provider would just list recent mail.
      if (isTauri() && text && isBare(filter) && buildFtsMatch(text)) {
        const extra = await providerHits(externalAccounts, text, new Set(allResults.map(c => c.key)));
        if (seq !== searchSeq.current) return;
        if (extra.length) {
          allResults.push(...extra);
          allResults.sort((a, b) => new Date(b.updated_at) - new Date(a.updated_at));
          setResults([...allResults]);
        }
      }

      // A dead-end query gets a spelling suggestion — from whichever half of the
      // search has one (MX comes back with it; local channels are looked up here).
      // Only words can be misspelled, so a filter-only search skips this.
      if (allResults.length || !text) {
        setSuggestion(null);
      } else {
        const hint = apiSuggestions.find(Boolean) || await localSuggestion(text);
        if (seq === searchSeq.current) setSuggestion(hint || null);
      }
    } catch (e) {
      log.error('Search', `Search failed: ${e?.message || e}`);
    } finally {
      if (seq === searchSeq.current) setLoading(false);
    }
  }, [organizations, externalAccounts, localWhatsApp]);

  // Run search on mount / query change from the URL (the shared chrome search
  // navigates here with ?q=…; the results follow the URL).
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: fetch results for the URL query */
  useEffect(() => {
    if (!initialQuery) return;
    executeSearch(filter);
  }, [initialQuery, filter, executeSearch]);
  /* eslint-enable react-hooks/set-state-in-effect */

  // Offer the correction, never run it: an auto-redirect hides what the user
  // actually typed, and a suggestion drawn from their own mail is a guess, not
  // a certainty. The dead end stays on screen with one click out of it.
  const searchFor = useCallback((q) => {
    navigate(`?q=${encodeURIComponent(q)}`);
  }, [navigate]);

  const handleClearSearch = useCallback(() => {
    const canGoBack = useNavigationStore.getState().canGoBack();
    if (canGoBack) {
      useNavigationStore.getState().goBack();
    } else {
      navigate(orgSlug ? `/${orgSlug}/mail` : '/mail');
    }
  }, [navigate, orgSlug]);

  // Load detail for the selected result.
  // WhatsApp hits have no conversation detail to load (WaChatPane reads them).
  const mailResults = useMemo(() => results.filter(c => !c.waChat), [results]);
  useSelectedConversationDetail({
    selectedId,
    conversations: mailResults,
    setSelectedConv,
    setEnrichingKeys,
    logTag: 'SearchDetail',
  });

  const handleResultSelect = useCallback((conv) => {
    setSelectedId(conv.id);
  }, []);

  // Route sends/undo through the selected conversation's provider for external
  // (local-channel) results; org/MX results stay on the API path.
  const selectedResult = results.find(c => c.id === selectedId);

  const { hoverPreview, handleCardHover, handleCardHoverEnd, handlePopupMouseEnter, handlePopupMouseLeave, closePreview } = useHoverPreview();

  // ── Right-click context menu (same items as the inbox views); the preview
  // popup is hover-only (3s dwell in useHoverPreview). ──
  // Cmd/shift-click multi-select inside a column; the right-click menu then acts
  // on the whole batch (see useColumnSelection).
  const { selectedIds, clearSelection: clearMultiSelect, handleRowClick, keepOrResetSelection } = useColumnSelection();

  const [contextMenu, setContextMenu] = useState({ open: false, position: null, conv: null });
  const closeContextMenu = useCallback(() => setContextMenu({ open: false, position: null, conv: null }), []);
  const handleResultContextMenu = useCallback((conv, e) => {
    e.preventDefault();
    // Keep the event from reaching ContextMenu's window-level dismiss listener,
    // which would close the menu in the same right-click that opened it.
    e.stopPropagation();
    closePreview();
    // Right-clicking outside the batch drops it — the menu then means this row.
    keepOrResetSelection(conv);
    setContextMenu({ open: true, position: { x: e.clientX, y: e.clientY }, conv });
  }, [closePreview, keepOrResetSelection]);

  // Reply/forward from the menu: select the result first (loads its messages),
  // then fire the compose intent once the detail catches up.
  const requestCompose = usePendingCompose({
    selectedConv,
    onSelectConversation: (conv) => setSelectedId(conv.id),
  });

  // Backend dispatch for a result action, routed to the hit's own channel
  // (external → provider FFI, org/MX → bulk API).
  // `unreadNow` is the thread's unread state at the moment of the call. It
  // defaults to the row's, but undo has to pass it: `conv` is captured before
  // the forward action, so after a mark-as-read its .read is stale and the undo
  // would compute a zero delta and leave the badge one short.
  const dispatchResultAction = useCallback(async (conv, action, unreadNow = !conv.read) => {
    // Search holds no inbox list, so nothing here re-derives the badge — move it
    // directly, before the write, or it stays stale until the next recount.
    // Applied once at the single dispatch point so every caller below (removal,
    // mark read/unread, restore, undo, redo) is covered without repeating it.
    // Results span folders (that's what the status badge on a row means), and
    // only the ones in the inbox pool are in the count: deleting a hit that
    // already lives in Spam must not decrement it.
    const delta = unreadDelta(action, unreadNow, conv.status === CONV_STATUS.OPEN);
    if (delta) useUnreadStore.getState().adjust(conv.accountKey, delta);
    const revertUnread = () => { if (delta) useUnreadStore.getState().adjust(conv.accountKey, -delta); };
    if (conv.providerType !== 'inbox2') {
      if (!isTauri()) return;
      try {
        const { performAction } = await import('../../lib/providers/index.js');
        await performAction(conv.accountKey, [conv.id], action);
      } catch (e) {
        revertUnread();
        log.warn('SearchAction', `${action} failed: ${e?.message || e}`);
      }
      return;
    }
    // false = the server refused it; the caller reverts its optimistic patch.
    const ok = await commitAction(action, () => api.bulkConversations(conv.accountKey, [conv.id], action));
    if (!ok) revertUnread();
    return ok;
  }, []);

  // Patch a hit in the results list + the open detail pane.
  const patchResult = useCallback((id, patch) => {
    setResults(prev => prev.map(c => c.id === id ? { ...c, ...patch } : c));
    setSelectedConv(prev => prev && prev.id === id ? { ...prev, ...patch } : prev);
  }, []);

  // Perform an action on a result with optimistic UI + undo recording —
  // mirrors the unified inbox's performConversationAction semantics.
  const performResultAction = useCallback(async (conv, action, { record = true, batch = null } = {}) => {
    if (!conv) return;

    // Restore a cross-folder hit (search spans trash/spam/archive) back to the
    // inbox. The hit stays in the results — only its folder badge changes.
    if (action === CONV_ACTION.MOVE_TO_INBOX) {
      const fromStatus = conv.status;
      const forward = STATUS_FORWARD_ACTION[fromStatus];
      // External restores via the matching un-* verb; org sets status open.
      const restoreVerb = conv.providerType !== 'inbox2' ? REVERSE_VERB[forward] : CONV_STATUS.OPEN;
      if (!restoreVerb) return;
      const doMove = async () => {
        patchResult(conv.id, { status: CONV_STATUS.OPEN });
        // Refused: put the badge back — the thread never left its folder.
        if (await dispatchResultAction(conv, restoreVerb) === false) {
          patchResult(conv.id, { status: fromStatus });
          return false;
        }
      };
      if (await doMove() === false) return;
      if (record) {
        useUndoStore.getState().record({
          batch,
          description: `Moved "${conv.subject || 'conversation'}" to Inbox`,
          batchDescription: (n) => `Moved ${n} conversations to Inbox`,
          icon: 'tray.and.arrow.down',
          key: conv.id,
          undo: () => {
            patchResult(conv.id, { status: fromStatus });
            dispatchResultAction(conv, forward);
          },
          redo: doMove,
        });
      }
      return;
    }

    if (REMOVAL_ACTIONS.includes(action)) {
      const index = results.findIndex(c => c.id === conv.id);
      const snapshot = index >= 0 ? { conv: results[index], index } : null;
      // Put a removed hit back at its original slot — shared by undo and by the
      // revert when the server refuses the action.
      const reinsert = (status) => setResults(prev => {
        if (prev.some(c => c.id === conv.id)) return prev;
        const next = [...prev];
        next.splice(Math.min(snapshot?.index ?? next.length, next.length), 0,
          { ...(snapshot?.conv || conv), status });
        return next;
      });
      const doRemove = async () => {
        setResults(prev => prev.filter(c => c.id !== conv.id));
        setSelectedId(prev => prev === conv.id ? null : prev);
        setSelectedConv(prev => prev && prev.id === conv.id ? null : prev);
        if (await dispatchResultAction(conv, action) === false) {
          reinsert(conv.status);
          return false;
        }
      };
      if (await doRemove() === false) return;
      if (record) {
        useUndoStore.getState().record({
          batch,
          description: `${REMOVAL_PAST_TENSE[action]} "${conv.subject || 'conversation'}"`,
          batchDescription: (n) => `${REMOVAL_PAST_TENSE[action]} ${n} conversations`,
          variant: action === CONV_ACTION.TRASH ? 'danger' : 'triage',
          icon: ACTION_ICON[action],
          key: conv.id,
          undo: () => {
            dispatchResultAction(conv, conv.providerType !== 'inbox2' ? REVERSE_VERB[action] : CONV_STATUS.OPEN);
            reinsert(CONV_STATUS.OPEN);
          },
          redo: doRemove,
        });
      }
      return;
    }

    if (action === CONV_ACTION.MARK_READ || action === CONV_ACTION.MARK_UNREAD) {
      const read = action === CONV_ACTION.MARK_READ;
      const opposite = read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ;
      patchResult(conv.id, { read });
      if (await dispatchResultAction(conv, action) === false) {
        patchResult(conv.id, { read: !read });
        return;
      }
      if (record) {
        useUndoStore.getState().record({
          batch,
          description: read ? 'Marked as read' : 'Marked as unread',
          batchDescription: (n) => `Marked ${n} conversations as ${read ? 'read' : 'unread'}`,
          icon: ACTION_ICON[action],
          key: conv.id,
          undo: () => { patchResult(conv.id, { read: !read }); dispatchResultAction(conv, opposite, !read); },
          redo: () => { patchResult(conv.id, { read }); dispatchResultAction(conv, action); },
        });
      }
      return;
    }

    dispatchResultAction(conv, action);
  }, [results, dispatchResultAction, patchResult]);

  // Set urgent/important on a result. External uses the provider FFI; org/MX
  // stores priority as tags (lib/mxPriority).
  const runResultPriority = useCallback(async (conv, urgent, important) => {
    if (!conv) return;
    const triaged = urgent || important;
    const patch = { urgent, important, triaged, quadrant: triaged ? getQuadrant(urgent, important) : null };
    patchResult(conv.id, patch);
    try {
      if (conv.providerType !== 'inbox2') {
        if (!isTauri()) return;
        const providers = await import('../../lib/providers/index.js');
        if (triaged) await providers.setPriority(conv.accountKey, [conv.id], urgent, important);
        else await providers.clearPriority(conv.accountKey, [conv.id]);
      } else if (triaged) {
        await setMxPriorityTags(conv.accountKey, conv, { urgent, important });
      } else {
        await clearMxPriorityTags(conv.accountKey, conv);
      }
    } catch (e) { log.warn('SearchPriority', `Failed: ${e?.message || e}`); }
  }, [patchResult]);

  // Priority + undo recording (mirrors useUnifiedInbox.applyPriority).
  const applyResultPriority = useCallback(async (conv, urgent, important, { record = true, batch = null } = {}) => {
    if (!conv) return;
    const prev = { urgent: conv.urgent, important: conv.important, triaged: conv.triaged };
    await runResultPriority(conv, urgent, important);
    if (!record) return;
    const triaged = urgent || important;
    useUndoStore.getState().record({
      batch,
      description: triaged ? `Moved to ${getQuadrant(urgent, important).label}` : 'Removed priority',
      batchDescription: (n) => triaged
        ? `Moved ${n} conversations to ${getQuadrant(urgent, important).label}`
        : `Removed priority from ${n} conversations`,
      variant: 'triage',
      icon: triaged ? getQuadrant(urgent, important).icon : 'tag.slash',
      key: conv.id,
      undo: () => runResultPriority(conv, prev.triaged ? prev.urgent : false, prev.triaged ? prev.important : false),
      redo: () => runResultPriority(conv, urgent, important),
    });
  }, [runResultPriority]);

  // ── Mass actions on the multi-selected rows ──
  const selectedConvs = useMemo(
    () => results.filter(c => selectedIds.has(c.id)),
    [results, selectedIds]
  );
  const hasUnreadInSelection = selectedConvs.some(c => !c.read);
  // One `batch` token per mass action folds the per-row undo records into a
  // single toast whose Undo puts every row back (see undoStore.record).
  const handleBulkAction = useCallback((action) => {
    const batch = Symbol('bulk');
    selectedConvs.forEach(c => performResultAction(c, action, { batch }));
    clearMultiSelect();
  }, [selectedConvs, performResultAction, clearMultiSelect]);
  const handleBulkPriority = useCallback((key) => {
    const batch = Symbol('bulk');
    selectedConvs.forEach(c => applyResultPriority(
      c,
      key ? QUADRANTS[key].urgent : false,
      key ? QUADRANTS[key].important : false,
      { batch }
    ));
  }, [selectedConvs, applyResultPriority]);

  const ctxConv = contextMenu.conv;
  // Right-click inside a multi-selection → the batch menu; otherwise the
  // single-conversation menu for the row under the cursor.
  const contextIsBulk = ctxConv && selectedIds.size > 1 && selectedIds.has(ctxConv.id);
  const ctxManualTriage = useManualTriage(contextIsBulk ? null : manualTriageTarget(ctxConv, orgId));
  const contextMenuItems = !ctxConv ? [] : contextIsBulk ? bulkActionMenuItems(selectedIds, {
    hasUnread: hasUnreadInSelection,
    onArchive: () => handleBulkAction(CONV_ACTION.ARCHIVE),
    onSpam: () => handleBulkAction(CONV_ACTION.SPAM),
    onTrash: () => handleBulkAction(CONV_ACTION.TRASH),
    onMarkReadUnread: () => handleBulkAction(hasUnreadInSelection ? CONV_ACTION.MARK_READ : CONV_ACTION.MARK_UNREAD),
    onMoveToInbox: () => handleBulkAction(CONV_ACTION.MOVE_TO_INBOX),
    executePriority: (_ids, key) => handleBulkPriority(key),
    afterAction: clearMultiSelect,
    // Search spans every folder, so the batch can always be sent back to Inbox.
    folderRole: null,
  }) : conversationContextMenuItems(ctxConv, {
    onReply: () => requestCompose(ctxConv, 'reply'),
    onReplyAll: () => requestCompose(ctxConv, 'reply-all'),
    onForward: () => requestCompose(ctxConv, 'forward'),
    onMarkReadUnread: () => performResultAction(ctxConv, ctxConv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ),
    onArchive: () => performResultAction(ctxConv, CONV_ACTION.ARCHIVE),
    onSpam: () => performResultAction(ctxConv, CONV_ACTION.SPAM),
    onTrash: () => performResultAction(ctxConv, CONV_ACTION.TRASH),
    onMoveToInbox: () => performResultAction(ctxConv, CONV_ACTION.MOVE_TO_INBOX),
    manualTriage: ctxManualTriage,
    // triageSubmenu passes (convIds, quadrantKey); clearing = both flags off.
    executePriority: (_ids, key) => applyResultPriority(
      ctxConv,
      key ? QUADRANTS[key].urgent : false,
      key ? QUADRANTS[key].important : false
    ),
  });

  // Mark a viewed result read per the user's preference (Outlook-style dwell).
  const markResultRead = useCallback((id) => {
    const conv = results.find(c => c.id === id);
    if (!conv || conv.read) return;
    // Dwell auto-read shouldn't pile up undo toasts.
    performResultAction(conv, CONV_ACTION.MARK_READ, { record: false });
  }, [results, performResultAction]);

  useMarkRead({
    conv: selectedResult
      ? { id: selectedResult.id, read: selectedResult.read, accountKey: selectedResult.accountKey }
      : null,
    markRead: markResultRead,
  });

  return (
    <>
      <div className={layoutStyles.body}>
        <div className={styles.main}>
          {/* ═══ SEARCH HEADER ═══ */}
          <div className={styles.searchHeader}>
            <Icon name="magnifyingglass" size={11} className={styles.searchHeaderIcon} />
            <span className={styles.searchHeaderLabel}>
              Results for <span className={styles.searchHeaderQuery}>{filter.text || initialQuery}</span>
            </span>
            <span className={styles.searchHeaderCount}>{results.length}</span>
            {/* Say what was searched, and offer the other scope — otherwise a
                deleted thread simply missing from the results looks like a bug
                (and, before this, one that came back looked like a failed
                delete). Only shown while the folder scope is the default; once
                a scope is picked the chip below says it. */}
            {!filter.in && (
              <>
                <span className={styles.searchHeaderScope}>All folders except Trash &amp; Spam</span>
                <button type="button" className={styles.searchHeaderScopeLink} onClick={toggleDiscarded}>
                  Include trash
                </button>
              </>
            )}
            {includeDiscarded && (
              <span className={styles.searchHeaderScope}>Everywhere, including Trash &amp; Spam</span>
            )}
            <div className={styles.searchHeaderDivider} />
            <button
              type="button"
              className={`${styles.searchHeaderFilters} ${filtersOpen ? styles.searchHeaderFiltersOn : ''}`}
              onClick={() => setFiltersOpen(true)}
              title="Filters"
            >
              <Icon name="line.3.horizontal.decrease" size={10} />
              Filters
            </button>
            <button className={styles.searchHeaderClose} onClick={handleClearSearch} title="Close search">
              <Icon name="xmark" size={10} />
            </button>
          </div>

          <SearchFilterChips filter={filter} onChange={setFilter} />
          <SearchFilterPopover
            open={filtersOpen}
            filter={filter}
            onChange={setFilter}
            onClose={() => setFiltersOpen(false)}
          />

          {loading ? (
            <div className={styles.loadingState}>
              <Icon name="magnifyingglass" size={24} />
              <span>Searching…</span>
            </div>
          ) : results.length === 0 ? (
            <div className={styles.emptyState}>
              <Icon name="magnifyingglass" size={32} className={styles.emptyIcon} />
              <div className={styles.emptyTitle}>No results</div>
              <div className={styles.emptyMessage}>
                {filter.text
                  ? <>No conversations match &ldquo;{filter.text}&rdquo;{isBare(filter) ? '' : ' with these filters'}</>
                  : 'No conversations match these filters'}
              </div>
              {suggestion && (
                <button className={styles.suggestionLink} onClick={() => searchFor(suggestion)}>
                  Did you mean <strong>{suggestion}</strong>?
                </button>
              )}
            </div>
          ) : (
            /* ═══ PER-CHANNEL COLUMNS + DETAIL ═══ */
            <div className={styles.listViewLayout}>
              <ListViewColumns
                conversations={results}
                channelStates={channelStates}
                accounts={accounts}
                selectedId={selectedId}
                selectedIds={selectedIds}
                onRowClick={handleRowClick}
                onSelect={handleResultSelect}
                onContextMenu={(conv, e) => (conv.waChat ? e.preventDefault() : handleResultContextMenu(conv, e))}
                onHover={(conv, e) => { if (!conv.waChat) handleCardHover(conv, e); }}
                onHoverEnd={handleCardHoverEnd}
              />
              <section className={styles.listViewDetail}>
                <DotMatrix />
                {selectedResult?.waChat ? (
                  <WaChatPane key={selectedResult.id} chat={selectedResult.waChat} anchorId={selectedResult.waMsgId} />
                ) : selectedConv ? (
                  <ConversationDetail
                    conversation={selectedConv}
                    defaultFrom={defaultFrom}
                    orgId={orgId}
                    onArchive={() => performResultAction(selectedResult, CONV_ACTION.ARCHIVE)}
                    onTrash={() => performResultAction(selectedResult, CONV_ACTION.TRASH)}
                    onConversationAction={(action) => performResultAction(selectedResult, action)}
                    executePriority={(_ids, key) => applyResultPriority(
                      selectedResult,
                      key ? QUADRANTS[key].urgent : false,
                      key ? QUADRANTS[key].important : false
                    )}
                    wasUnread={false}
                    focusedMsgIndex={-1}
                    enrichingKeys={enrichingKeys}
                  />
                ) : (
                  <div className={styles.listViewDetailEmpty}>
                    <Icon name="magnifyingglass" size={32} className={styles.listViewDetailIcon} />
                    <span>Select a result to view</span>
                  </div>
                )}
              </section>
            </div>
          )}
        </div>
      </div>

      {hoverPreview.conv && (
        <EmailPreviewPopup
          conversation={hoverPreview.conv}
          anchorRect={hoverPreview.rect}
          onClose={closePreview}
          onView={() => { closePreview(); handleResultSelect(hoverPreview.conv); }}
          onArchive={() => { closePreview(); performResultAction(hoverPreview.conv, CONV_ACTION.ARCHIVE); }}
          onTrash={() => { closePreview(); performResultAction(hoverPreview.conv, CONV_ACTION.TRASH); }}
          onMarkRead={() => { closePreview(); performResultAction(hoverPreview.conv, hoverPreview.conv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ); }}
          onUrgent={() => { closePreview(); applyResultPriority(hoverPreview.conv, !hoverPreview.conv.urgent, hoverPreview.conv.important); }}
          onImportant={() => { closePreview(); applyResultPriority(hoverPreview.conv, hoverPreview.conv.urgent, !hoverPreview.conv.important); }}
          onPopupMouseEnter={handlePopupMouseEnter}
          onPopupMouseLeave={handlePopupMouseLeave}
        />
      )}

      <ContextMenu
        open={contextMenu.open}
        position={contextMenu.position}
        items={contextMenuItems}
        onClose={closeContextMenu}
      />

      <MessageShortcuts conversation={selectedConv} orgId={orgId} defaultFrom={defaultFrom} />
      <ShortcutsHelp open={helpOpen} onClose={() => setHelpOpen(false)} />
      <UndoToast entries={undoToasts} onUndo={undoAction} onDismiss={dismissUndo} />
    </>
  );
}
