import { lazy, Suspense, useState, useEffect, useCallback, useMemo, useRef } from 'react';
import { AnimatePresence } from 'motion/react';
import { useParams, useNavigate, useSearchParams } from 'react-router';
import { DndContext, DragOverlay, PointerSensor, KeyboardSensor, useSensor, useSensors } from '@dnd-kit/core';
import useAuth from '../../hooks/useAuth';
import useTheme from '../../hooks/useTheme';
import useAccounts from '../../hooks/useAccounts';
import useSpaces from '../../hooks/useSpaces';
import { resolveWorkspace } from '../../lib/workspace';
import useUnifiedInbox from '../../hooks/useUnifiedInbox';
import useUndoStore from '../../stores/undoStore';
import useInboxDragDrop from '../../hooks/useInboxDragDrop';
import useHoverPreview from '../../hooks/useHoverPreview';
import useColumnSelection from '../../hooks/useColumnSelection';
import useMarkRead from '../../hooks/useMarkRead';
import usePendingCompose from '../../hooks/usePendingCompose';
import { UNIFIED_VIEW_MODE, UNIFIED_UNREAD_ONLY, PREVIEW_PANE_MODE } from '../../lib/storageKeys';
import usePaneMode, { paneModeIcon } from '../../hooks/usePaneMode';
import { PaneModeMenu, PaneStrip } from '../../components/PaneMode/PaneMode';
import { ToolbarButton } from '../../components/ToolbarGroup/ToolbarGroup';
import useSelectedConversationDetail from '../../hooks/useSelectedConversationDetail';
import log from '../../lib/log';
import AddAccountModal from '../../components/AddAccountModal/AddAccountModal';
import ChannelBar from '../../components/ChannelBar/ChannelBar';
import CalendarRail from '../../components/Calendar/CalendarRail';
import TouchStrip from '../../components/TouchStrip/TouchStrip';
import LorePanel from '../../components/Lore/LorePanel';
import { openLoreItem } from '../../components/Lore/openItem';
import EmailCard, { EmailCardGhost } from '../../components/EmailCard/EmailCard';
import EisenhowerMatrix from '../../components/EisenhowerMatrix/EisenhowerMatrix';
import ListViewColumns from '../../components/ListViewColumns/ListViewColumns';
import { GhostTriageBackdrop } from '../../components/Ghosts/Ghosts';
import ChannelEmptyState from '../../components/ChannelEmptyState/ChannelEmptyState';
import ConversationDetail from '../../components/ConversationDetail/ConversationDetail';
import DotMatrix from '../../components/DotMatrix';
// Lazy — see InboxPage: keeps the game chunk out of the entry bundle.
const DropBlock = lazy(() => import('../../components/DropBlock/DropBlock'));
import useDropBlockPref from '../../lib/dropBlockPref';
import useDelayedFlag from '../../hooks/useDelayedFlag';
import UndoToast from '../../components/UndoToast/UndoToast';
import EmailPreviewPopup from '../../components/EmailPreviewPopup/EmailPreviewPopup';
import useDrafts from '../../hooks/useDrafts';
import { useNewComposeFrom } from '../../hooks/useFromIdentities';
import NotificationPanel from '../../components/NotificationPanel/NotificationPanel';
import ChromeBar from '../../components/Chrome/ChromeBar';
import DraftProvider from '../../hooks/DraftProvider';
import { ComposeAction, ComposePopups } from '../../components/ComposeWidgets/ComposeWidgets';
import MessageShortcuts from '../../components/MessageShortcuts';
import ShortcutsHelp from '../../components/ShortcutsHelp';
import useShortcutHelp from '../../hooks/useShortcutHelp';
import { usePaletteActions } from '../../stores/paletteStore';
import useChromeSearch from '../../hooks/useChromeSearch';
import ContextMenu from '../../components/DropdownMenu/ContextMenu';
import { QUADRANTS } from '../../lib/priority';
import { filterUnread } from '../../lib/unreadFilter';
import { CONV_ACTION, REMOVAL_ACTIONS, conversationContextMenuItems, bulkActionMenuItems } from '../../lib/conversationActions';
import useManualTriage, { manualTriageTarget } from '../../hooks/useManualTriage';
import useNavigationStore from '../../stores/navigationStore';
import Icon from '../../components/Icon';
import syncManager from '../../lib/sync-manager';
import layoutStyles from '../../styles/layout.module.css';
import styles from './UnifiedInboxView.module.css';

export default function UnifiedInboxView() {
  const { orgSlug } = useParams();
  const navigate = useNavigate();
  const { user, organizations, currentOrgSlug } = useAuth();
  const { mode, themeId } = useTheme();
  // `allAccounts` = the per-DOMAIN workspace tabs (one per domain + externals),
  // shared with InboxPage so the top ChromeBar tabs are identical on the unified
  // and single-domain views. The same list drives useUnifiedInbox, so each
  // domain gets its own independently-loading column.
  const { allAccounts, externalAccounts, addAccount, reorderAccounts } = useAccounts(organizations);

  const navIsRestoring = useNavigationStore(s => s._isRestoring);

  // The unified route has no :orgSlug, so fall back to the session's current org
  // (or the user's first). Without this, orgId is undefined and every Rails
  // draft/message call hits /orgs/undefined/… (404/401). Stays undefined only
  // for a user with no org at all (pure external accounts) — handled downstream.
  // The slug may name a specific domain (/:domainSlug/mail) — resolve it to the
  // org and use the org's public id, since a non-primary domain slug matches
  // neither an org key nor an org slug on the API.
  const effectiveOrgSlug = orgSlug || currentOrgSlug || organizations?.[0]?.slug || organizations?.[0]?.id;
  const currentOrg = resolveWorkspace(organizations, effectiveOrgSlug).org
    || organizations?.find(o => o.slug === effectiveOrgSlug || o.id === effectiveOrgSlug);
  const orgId = currentOrg?.id || effectiveOrgSlug;
  const defaultFrom = currentOrg?.domain ? `${user?.username}@${currentOrg.domain}` : '';

  // Undo (cmd+z / toast) re-selects the restored conversation. The selection
  // setter is declared below, so route through a ref the hook can call lazily.
  const restoreSelectRef = useRef(null);
  const handleRestoreSelect = useCallback((convId) => {
    restoreSelectRef.current?.(convId);
  }, []);

  // ── Space drill-in (?space=<slug> from the Spaces treemap) ──
  // Narrows every channel to one Space: MX via the API space key, local
  // channels via the on-device classifier's space_slug. The unified inbox is
  // the drill target because it's the one view that renders both pools.
  const [searchParams, setSearchParams] = useSearchParams();
  const spaceSlug = searchParams.get('space');
  const { spaces: orgSpaces } = useSpaces(spaceSlug ? effectiveOrgSlug : null);
  const spaceFilter = useMemo(() => {
    if (!spaceSlug) return null;
    const s = (orgSpaces || []).find(x => x.id === spaceSlug || x.slug === spaceSlug || x.key === spaceSlug);
    return {
      slug: s?.slug || s?.id || spaceSlug,
      key: s?.key || (spaceSlug.startsWith('spc_') ? spaceSlug : null),
      name: s?.name || spaceSlug,
    };
  }, [spaceSlug, orgSpaces]);
  const clearSpaceFilter = useCallback(() => {
    setSearchParams(prev => {
      const p = new URLSearchParams(prev);
      p.delete('space');
      return p;
    }, { replace: true });
  }, [setSearchParams]);

  const {
    conversations,
    allConversations,
    channelStates,
    toggleChannel,
    priorityFilter,
    applyPriority,
    removePriority,
    performConversationAction,
    accounts,
    loading,
    loadMoreColumn,
    loadMoreAllColumns,
  } = useUnifiedInbox(allAccounts, handleRestoreSelect, spaceFilter);

  const undoToasts = useUndoStore(s => s.toasts);
  const undoAction = useUndoStore(s => s.undo);
  const dismissUndo = useUndoStore(s => s.dismiss);

  // UI state
  const [notifOpen, setNotifOpen] = useState(false);
  const [addAccountOpen, setAddAccountOpen] = useState(false);
  const [viewMode, setViewMode] = useState(() => localStorage.getItem(UNIFIED_VIEW_MODE) || 'grid');
  const { enabled: dropBlockEnabled } = useDropBlockPref();
  const [unreadOnly, setUnreadOnly] = useState(() => localStorage.getItem(UNIFIED_UNREAD_ONLY) === '1');
  const { searchProps } = useChromeSearch(orgSlug);

  // ── List view: conversation selection + detail loading ──
  const [selectedListId, setSelectedListId] = useState(null);
  // Reading pane: pinned / floating / hidden (Rider-style). The ref wraps the
  // pane and its strip; clicking a row never dismisses it — selecting reopens.
  const previewRef = useRef(null);
  const preview = usePaneMode(PREVIEW_PANE_MODE, previewRef, '[data-conv-id]');
  const { setOpen: setPreviewOpen } = preview;
  const [selectedConv, setSelectedConv] = useState(null);
  const [enrichingKeys, setEnrichingKeys] = useState(new Set());
  // The pane is idle whenever no conversation detail is shown. Defer the game a
  // beat so it doesn't flash during navigation / detail-load gaps.
  const showDropBlock = useDelayedFlag(!selectedConv);

  // Mirror the nav store's open conversation into the local list selection:
  // on back/forward (navIsRestoring) and on initial load / direct URL entry
  // (a ?c= that syncFromUrl put in the store before this view could adopt it).
  const navConversationId = useNavigationStore(s => s.conversationId);
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: restore selection from nav state */
  useEffect(() => {
    if (viewMode !== 'list') return;
    if (navIsRestoring) {
      if (navConversationId) setSelectedListId(navConversationId);
      useNavigationStore.getState().consumeIsRestoring();
    } else if (navConversationId && !selectedListId) {
      setSelectedListId(navConversationId);
    }
  }, [navIsRestoring, viewMode, navConversationId, selectedListId]);
  /* eslint-enable react-hooks/set-state-in-effect */

  const handleViewModeChange = useCallback((mode) => {
    setViewMode(mode);
    localStorage.setItem(UNIFIED_VIEW_MODE, mode);
    if (mode === 'grid') setSelectedListId(null);
  }, [setSelectedListId]);

  // Switch to individual account view
  const handleSwitchAccount = useCallback((key) => {
    const acct = allAccounts.find(a => a.key === key);
    if (acct?.provider_type === 'inbox2') {
      // MX domain tab → its own workspace path (/:domainSlug/mail/inbox), same
      // as ChromeBar. Navigate directly — the navigation store can't distinguish
      // unified vs per-account for the same org, so syncFromUrl handles state.
      navigate(`/${acct.domainSlug || acct.orgSlug}/mail/inbox`);
    } else {
      useNavigationStore.getState().navigateTo({ accountKey: key, conversationId: null });
    }
  }, [allAccounts, navigate]);

  // Register + kick off the first sync for a newly-connected external account
  // (same for Gmail and Microsoft — the provider only differs upstream).
  const handleAccountConnected = useCallback(async (acct) => {
    addAccount(acct);
    setAddAccountOpen(false);
    try {
      await syncManager.init();
      syncManager.register(acct.key);
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('start_sync', { accountKey: acct.key });
    } catch (e) { log.error('AccountSync', `Sync start failed: ${e.message || e}`); }
  }, [addAccount]);

  const selectedRef = allConversations.find(c => c.id === selectedListId);
  // Reply/forward fall back to the selected thread's own channel (same rule as
  // search) — the org address can't send a Gmail/Microsoft thread's reply.
  const replyFrom = externalAccounts.find(a => a.key === selectedRef?.accountKey)?.email_address || defaultFrom;

  // The unread view pins the open row so it survives the reading pane marking
  // it read. Decided once per selection, from its read state at that moment:
  // a row opened unread is pinned until you move off it; one already read
  // (a ?c= restore, a selection carried in from the all-mail view) isn't.
  const [pin, setPin] = useState({ sel: null, id: null });
  if (pin.sel !== selectedListId && (selectedRef || !selectedListId)) {
    setPin({ sel: selectedListId, id: selectedRef && !selectedRef.read ? selectedListId : null });
  }
  const pinnedId = pin.id;

  const clearSelection = useCallback(() => {
    setSelectedListId(null);
    setSelectedConv(null);
    useNavigationStore.getState().navigateTo({ conversationId: null }, { replace: true, replaceStack: true });
  }, [setSelectedListId, setSelectedConv]);

  const toggleUnreadOnly = useCallback(() => {
    const next = !unreadOnly;
    setUnreadOnly(next);
    localStorage.setItem(UNIFIED_UNREAD_ONLY, next ? '1' : '0');
  }, [unreadOnly]);

  // While the filter is on, a channel's checkbox says exactly what its column
  // says: checked only while the channel still has something to show. Derived
  // rather than written into the disabled set, so a channel unchecks itself as
  // its last unread is read and re-checks when new mail lands.
  // ponytail: a checkbox with nothing unread behind it is inert — clicking it
  // can't reveal anything the filter hides.
  const displayChannelStates = useMemo(() => {
    if (!unreadOnly) return channelStates;
    const shown = new Set(
      filterUnread(allConversations, true, pinnedId).map(c => c.accountKey)
    );
    return Object.fromEntries(Object.entries(channelStates).map(
      ([key, s]) => [key, { ...s, enabled: s.enabled && shown.has(key) }]
    ));
  }, [unreadOnly, channelStates, allConversations, pinnedId]);

  useSelectedConversationDetail({
    selectedId: selectedListId,
    conversations: allConversations,
    setSelectedConv,
    setEnrichingKeys,
    logTag: 'ListDetail',
  });

  const handleListSelect = useCallback((conv) => {
    setSelectedListId(conv.id);
    setPreviewOpen(true);
    // Track in nav manager + ride ?c= in the URL so a refresh reopens it.
    useNavigationStore.getState().navigateTo({ conversationId: conv.id }, { replace: true, replaceStack: true });
  }, [setSelectedListId, setPreviewOpen]);

  // Implementation for the undo re-select ref (declared above the inbox hook):
  // restore the cursor to the conversation that undo just brought back.
  useEffect(() => {
    restoreSelectRef.current = (convId) => {
      setSelectedListId(convId);
      useNavigationStore.getState().navigateTo({ conversationId: convId }, { replace: true, replaceStack: true });
    };
  }, [setSelectedListId]);

  // After removing the selected conversation, advance the cursor to the next
  // row in its column (same account) — mirrors the channel view's
  // removeAndSelectNext. Falls back to the previous row when removing the last
  // one, and only to the empty state once the column is exhausted. The column
  // list mirrors what ListViewColumns shows (same account, same unreadOnly).
  const selectAfterRemoval = useCallback((conv) => {
    const column = allConversations.filter(c => c.accountKey === conv.accountKey);
    // Same rule as ListViewColumns, pinned on the row being removed — it's the
    // one we're advancing *from*, so the cursor needs its place in the list.
    const visible = filterUnread(column, unreadOnly, conv.id);
    const idx = visible.findIndex(c => c.id === conv.id);
    const remaining = visible.filter(c => c.id !== conv.id);
    const next = idx >= 0 ? (remaining[Math.min(idx, remaining.length - 1)] || null) : null;
    if (next) {
      setSelectedListId(next.id);
      useNavigationStore.getState().navigateTo({ conversationId: next.id }, { replace: true, replaceStack: true });
    } else {
      clearSelection();
    }
  }, [allConversations, unreadOnly, setSelectedListId, clearSelection]);

  // Perform an action and, when it removes the *currently open* conversation,
  // advance the cursor to the next one (mirrors the channel view's
  // removeAndSelectNext, which advances regardless of which control fired the
  // action — toolbar, row quick-action, hover popup, or keyboard).
  const performAndAdvance = useCallback((conv, action, opts) => {
    const done = performConversationAction(conv.id, conv.accountKey, action, opts);
    if (REMOVAL_ACTIONS.includes(action) && conv.id === selectedListId) {
      selectAfterRemoval(conv);
    }
    return done;
  }, [performConversationAction, selectedListId, selectAfterRemoval]);

  // Grid view: the stream is a horizontal rail of every column merged, so its
  // "bottom" is its right edge — nearing it asks every column for another page.
  const handleStreamScroll = useCallback((e) => {
    const el = e.currentTarget;
    if (el.scrollWidth - el.scrollLeft - el.clientWidth > el.clientWidth) return;
    loadMoreAllColumns();
  }, [loadMoreAllColumns]);

  // ── Multi-select in the columns + mass actions ──
  // Cmd/shift-click builds a batch inside one column; the right-click menu then
  // acts on the whole batch instead of the row under the cursor.
  const { selectedIds, clearSelection: clearMultiSelect, handleRowClick, keepOrResetSelection } = useColumnSelection();
  const selectedConvs = useMemo(
    () => allConversations.filter(c => selectedIds.has(c.id)),
    [allConversations, selectedIds]
  );
  const hasUnreadInSelection = selectedConvs.some(c => !c.read);

  // One `batch` token per mass action folds the per-row undo records into a
  // single toast whose Undo puts every row back (see undoStore.record).
  const handleBulkAction = useCallback((action) => {
    // The open conversation being part of a removed batch empties the reading
    // pane — no cursor advance to guess at, since the next rows may be going too.
    const clearsPane = REMOVAL_ACTIONS.includes(action) && selectedConvs.some(c => c.id === selectedListId);
    const batch = Symbol('bulk');
    selectedConvs.forEach(c => performConversationAction(c.id, c.accountKey, action, { batch }));
    if (clearsPane) clearSelection();
    clearMultiSelect();
  }, [selectedConvs, selectedListId, performConversationAction, clearSelection, clearMultiSelect]);

  const handleBulkPriority = useCallback((quadrantKey) => {
    const batch = Symbol('bulk');
    selectedConvs.forEach(c => {
      if (!quadrantKey) removePriority(c.id, c.accountKey, { batch });
      else applyPriority(c.id, c.accountKey, QUADRANTS[quadrantKey].urgent, QUADRANTS[quadrantKey].important, { batch });
    });
  }, [selectedConvs, applyPriority, removePriority]);

  // Every control that acts on the *open* conversation — reading-pane toolbar,
  // the per-message ellipsis menu, keyboard shortcuts — goes through this one
  // handler, so they all advance the cursor on a removal instead of leaving a
  // filed thread open in the pane.
  const actOnSelected = useCallback((action) => {
    if (selectedRef) performAndAdvance(selectedRef, action);
  }, [selectedRef, performAndAdvance]);

  const handleListArchive = useCallback(() => actOnSelected(CONV_ACTION.ARCHIVE), [actOnSelected]);
  const handleListTrash = useCallback(() => actOnSelected(CONV_ACTION.TRASH), [actOnSelected]);

  const handleShortcutTriage = useCallback((quadrantKey) => {
    if (!selectedRef) return;
    if (!quadrantKey) { removePriority(selectedRef.id, selectedRef.accountKey); return; }
    const q = QUADRANTS[quadrantKey];
    applyPriority(selectedRef.id, selectedRef.accountKey, q.urgent, q.important);
  }, [selectedRef, applyPriority, removePriority]);

  const { helpOpen, setHelpOpen } = useShortcutHelp();

  // Backspace / Delete → trash the selected row (matches the channel view)
  useEffect(() => {
    if (viewMode !== 'list') return;
    const handler = (e) => {
      if (e.key !== 'Backspace' && e.key !== 'Delete') return;
      const el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
      if (document.querySelector('[data-overlay-open]')) return;
      if (selectedIds.size > 0) { e.preventDefault(); handleBulkAction(CONV_ACTION.TRASH); return; }
      if (!selectedRef) return;
      e.preventDefault();
      handleListTrash();
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [viewMode, selectedRef, handleListTrash, selectedIds, handleBulkAction]);

  // Escape → deselect the open conversation and fall back to the empty reading pane
  useEffect(() => {
    if (viewMode !== 'list') return;
    const handler = (e) => {
      if (e.key !== 'Escape') return;
      const el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
      if (document.querySelector('[data-overlay-open]')) return;
      // A batch is the shallower state: Escape drops it before the open thread.
      if (selectedIds.size > 0) { e.preventDefault(); clearMultiSelect(); return; }
      if (!selectedListId) return;
      e.preventDefault();
      setSelectedListId(null);
      setSelectedConv(null);
      useNavigationStore.getState().navigateTo({ conversationId: null }, { replace: true, replaceStack: true });
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [viewMode, selectedListId, selectedIds, clearMultiSelect]);

  // Mark the conversation shown in the list-view reading pane as read,
  // following the user's Outlook-style preference (see useMarkRead).
  const markListRead = useCallback(
    (id, accountKey) => performConversationAction(id, accountKey, CONV_ACTION.MARK_READ),
    [performConversationAction]
  );
  // Only while the pane is actually showing the thread — a hidden/closed pane
  // must not mark rows read as the cursor moves.
  useMarkRead({
    conv: viewMode === 'list' ? selectedRef : null,
    enabled: viewMode === 'list' && preview.shown,
    markRead: markListRead,
  });

  const bodyRef = useRef(null);

  const { activeDragId, handleDragStart, handleDragEnd, handleDragCancel } = useInboxDragDrop({
    applyPriority, removePriority, performConversationAction,
  });
  const { hoverPreview, handleCardHover, handleCardHoverEnd, handlePopupMouseEnter, handlePopupMouseLeave, closePreview } = useHoverPreview();

  // ── Right-click context menu (same items as the channel inbox view) ──
  // The hover preview popup stays hover-only (3s dwell in useHoverPreview).
  const [contextMenu, setContextMenu] = useState({ open: false, position: null, conv: null });
  const closeContextMenu = useCallback(() => setContextMenu({ open: false, position: null, conv: null }), []);
  const handleRowContextMenu = useCallback((conv, e) => {
    e.preventDefault();
    // Keep the event from reaching ContextMenu's window-level dismiss listener,
    // which would close the menu in the same right-click that opened it.
    e.stopPropagation();
    closePreview();
    // Right-clicking outside the batch drops it — the menu then means this row.
    keepOrResetSelection(conv);
    setContextMenu({ open: true, position: { x: e.clientX, y: e.clientY }, conv });
  }, [closePreview, keepOrResetSelection]);

  const pointerSensor = useSensor(PointerSensor, { activationConstraint: { distance: 8 } });
  const keyboardSensor = useSensor(KeyboardSensor);
  const sensors = useSensors(pointerSensor, keyboardSensor);

  // Card click — navigate to conversation in per-account view
  const handleCardClick = useCallback((conv) => {
    if (conv.providerType === 'inbox2') {
      // Opens in the domain's single-channel InboxPage (/:domainSlug/mail/inbox),
      // not the unified inbox — unified:false so it lands as a distinct history
      // entry and back works. The column key is a domain id; route by its slug.
      const acct = allAccounts.find(a => a.key === conv.accountKey);
      const slug = acct?.domainSlug || acct?.orgSlug || conv.accountKey;
      useNavigationStore.getState().navigateTo({ orgSlug: slug, accountKey: null, conversationId: conv.id, unified: false });
    } else {
      useNavigationStore.getState().navigateTo({ accountKey: conv.accountKey, conversationId: conv.id });
    }
  }, [allAccounts]);

  // Hover quick-actions on a row (mark read/unread, archive, delete). The verb
  // is computed in the row from CONV_ACTION; we just route it to the channel.
  const handleQuickAction = useCallback((conv, action) => {
    performAndAdvance(conv, action);
  }, [performAndAdvance]);

  // Forward from a row's hover quick-actions. Selects the conversation first if
  // its messages aren't loaded yet, then fires the compose-forward intent that
  // MessageShortcuts (inside the DraftProvider) turns into a forward draft.
  const requestCompose = usePendingCompose({
    selectedConv,
    onSelectConversation: handleListSelect,
  });
  const handleForward = useCallback((conv) => requestCompose(conv, 'forward'), [requestCompose]);

  const ctxConv = contextMenu.conv;
  // Right-click inside a multi-selection → the batch menu (Archive all, Delete
  // all, …); otherwise the single-conversation menu for the clicked row.
  const contextIsBulk = ctxConv && selectedIds.size > 1 && selectedIds.has(ctxConv.id);
  const ctxManualTriage = useManualTriage(contextIsBulk ? null : manualTriageTarget(ctxConv, orgId));
  const contextMenuItems = !ctxConv ? [] : contextIsBulk ? bulkActionMenuItems(selectedIds, {
    hasUnread: hasUnreadInSelection,
    onArchive: () => handleBulkAction(CONV_ACTION.ARCHIVE),
    onSpam: () => handleBulkAction(CONV_ACTION.SPAM),
    onTrash: () => handleBulkAction(CONV_ACTION.TRASH),
    onMarkReadUnread: () => handleBulkAction(hasUnreadInSelection ? CONV_ACTION.MARK_READ : CONV_ACTION.MARK_UNREAD),
    executePriority: (_ids, key) => handleBulkPriority(key),
    afterAction: clearMultiSelect,
    // Unified inbox is always the inbox — never a restorable folder.
    folderRole: null,
  }) : conversationContextMenuItems(ctxConv, {
    onReply: () => requestCompose(ctxConv, 'reply'),
    onReplyAll: () => requestCompose(ctxConv, 'reply-all'),
    onForward: () => requestCompose(ctxConv, 'forward'),
    onMarkReadUnread: () => performConversationAction(ctxConv.id, ctxConv.accountKey, ctxConv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ),
    onArchive: () => performAndAdvance(ctxConv, CONV_ACTION.ARCHIVE),
    onSpam: () => performAndAdvance(ctxConv, CONV_ACTION.SPAM),
    onTrash: () => performAndAdvance(ctxConv, CONV_ACTION.TRASH),
    // Unified inbox is always the inbox: never hide Archive on a row whose
    // conversation status is 'archived' (Gmail mixed-label threads).
    folderRole: null,
    manualTriage: ctxManualTriage,
    // triageSubmenu passes (convIds, quadrantKey); route to this conv's channel.
    executePriority: (_ids, key) => {
      if (!key) removePriority(ctxConv.id, ctxConv.accountKey);
      else applyPriority(ctxConv.id, ctxConv.accountKey, QUADRANTS[key].urgent, QUADRANTS[key].important);
    },
  });

  // Lore's Today panel acts on threads this view already holds through the
  // inbox's own dispatcher (so the row leaves its column, with the usual undo
  // toast); anything not loaded here Lore archives itself (see useLore).
  // Returns null when not ours, else a promise of whether the action landed.
  // `batch` folds a group action (Archive 8) into one undo toast.
  const loreDispatch = useCallback((item, action, { batch } = {}) => {
    const conv = allConversations.find(c => c.id === item.id);
    return conv ? performAndAdvance(conv, action, { batch }) : null;
  }, [allConversations, performAndAdvance]);
  const handleLoreOpen = useCallback((item) => {
    const conv = allConversations.find(c => c.id === item.id);
    if (conv && viewMode === 'list') handleListSelect(conv);
    else if (conv) handleCardClick(conv);
    else openLoreItem(item, organizations);
  }, [allConversations, viewMode, handleListSelect, handleCardClick, organizations]);

  // Cmd+/ toggle list/grid view, Cmd+U unread-only filter. (Cmd+P opens the
  // palette itself — mounted globally in routes.jsx.)
  useEffect(() => {
    const handler = (e) => {
      if (!(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey) return;
      if (e.key === '/') {
        e.preventDefault();
        handleViewModeChange(viewMode === 'grid' ? 'list' : 'grid');
      } else if (e.key === 'u' || e.key === 'U') {
        e.preventDefault();
        toggleUnreadOnly();
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [viewMode, handleViewModeChange, toggleUnreadOnly]);

  // Active drag conversation for overlay
  const activeDragConv = activeDragId
    ? allConversations.find(c => c.id === activeDragId)
    : null;

  return (
    <DraftProvider orgId={orgId} activeAccountKey={selectedRef && selectedRef.providerType !== 'inbox2' ? selectedRef.accountKey : undefined}>
    <DndContext
      sensors={sensors}
      onDragStart={handleDragStart}
      onDragEnd={handleDragEnd}
      onDragCancel={handleDragCancel}
    >
    <div className={layoutStyles.app} data-theme={mode} data-theme-variant={themeId}>
      <ChromeBar
        activeTab="mail"
        accounts={allAccounts}
        onReorder={reorderAccounts}
        onNotifications={() => setNotifOpen(true)}
        searchProps={searchProps}
      >
        <ComposeAction defaultFrom={defaultFrom} rememberLast />
      </ChromeBar>

      <div ref={bodyRef} className={layoutStyles.body}>
        {/* ═══ MAIN CONTENT (no sidebar) ═══ */}
        <div className={styles.main}>
          <ChannelBar
            channelStates={displayChannelStates}
            onToggle={toggleChannel}
            unreadOnly={unreadOnly}
            onToggleUnread={toggleUnreadOnly}
            accounts={accounts}
            onSwitchAccount={handleSwitchAccount}
            onAddAccount={() => setAddAccountOpen(true)}
            onReorder={reorderAccounts}
            viewMode={viewMode}
            onViewModeChange={handleViewModeChange}
          />

          {spaceFilter && (
            <div className={layoutStyles.spaceFilterBar}>
              <Icon name="square.grid.2x2" size={12} />
              <span className={layoutStyles.spaceFilterLabel}>{`Space · ${spaceFilter.name}`}</span>
              <button
                type="button"
                className={layoutStyles.spaceFilterClear}
                onClick={clearSpaceFilter}
                title="Clear space filter"
                aria-label="Clear space filter"
              >
                <Icon name="xmark" size={8} />
              </button>
            </div>
          )}

          {loading ? (
            <div className={styles.loadingState}>
              <Icon name="tray.2" size={32} />
              <span>Loading your inbox…</span>
            </div>
          ) : conversations.length === 0 && viewMode === 'grid' ? (
            <div className={styles.emptyState}>
              <GhostTriageBackdrop />
              <div className={styles.emptyContent}>
                <ChannelEmptyState
                  iconSrc="/logo-cube.png"
                  title={accounts.length === 0 ? 'No accounts connected' : 'All caught up'}
                  message={accounts.length === 0
                    ? 'Connect a mailbox to see your mail here.'
                    : 'Nothing matches your filters.'}
                >
                  {accounts.length === 0 && (
                    <button className={styles.emptyAction} onClick={() => setAddAccountOpen(true)}>
                      <Icon name="plus" size={14} />
                      Add account
                    </button>
                  )}
                </ChannelEmptyState>
              </div>
            </div>
          ) : viewMode === 'list' ? (
            /* ═══ LIST VIEW — per-account columns + detail ═══ */
            <div className={styles.listViewLayout}>
              <ListViewColumns
                conversations={allConversations}
                /* Raw states, not displayChannelStates: the lanes do their own
                   unread filtering, and a lane hidden by it must still count
                   as enabled so it leaves a same-width gap behind. */
                channelStates={channelStates}
                accounts={accounts}
                selectedId={selectedListId}
                selectedIds={selectedIds}
                onRowClick={handleRowClick}
                onSelect={handleListSelect}
                onOpen={handleCardClick}
                onContextMenu={handleRowContextMenu}
                onQuickAction={handleQuickAction}
                onForward={handleForward}
                unreadOnly={unreadOnly}
                pinnedId={pinnedId}
                onShowAll={toggleUnreadOnly}
                onColumnEndReached={loadMoreColumn}
                asideColumn={<CalendarRail orgSlug={effectiveOrgSlug} />}
              />
              <div ref={previewRef} className={styles.previewPane}>
              {preview.shown && (
              <section className={styles.listViewDetail} data-floating={preview.floating ? 'true' : undefined}>
                <DotMatrix />
                {selectedConv ? (
                  <ConversationDetail
                    headerExtra={<PaneModeMenu pane={preview} label="Reading pane" trigger={<ToolbarButton icon={paneModeIcon(preview.mode)} color="sage" title="Reading pane" />} />}
                    conversation={selectedConv}
                    defaultFrom={replyFrom}
                    orgId={selectedRef?.providerType === 'inbox2' ? (selectedRef.orgKey || selectedRef.accountKey) : orgId}
                    onArchive={handleListArchive}
                    onTrash={handleListTrash}
                    onConversationAction={actOnSelected}
                    executePriority={(_ids, key) => handleShortcutTriage(key)}
                    wasUnread={false}
                    focusedMsgIndex={-1}
                    enrichingKeys={enrichingKeys}
                  />
                ) : dropBlockEnabled ? (
                  // Show the game only once the pane has been genuinely idle for a
                  // beat — otherwise it flashes during the gap between selecting /
                  // restoring a conversation and its detail loading.
                  showDropBlock ? <Suspense fallback={<div className={styles.listViewDetailEmpty} />}><DropBlock /></Suspense> : <div className={styles.listViewDetailEmpty} />
                ) : (
                  <div className={styles.listViewDetailEmpty}>
                    <img src="/logo-cube.png" alt="" width={44} height={44} className={styles.listViewDetailIcon} />
                    <span>Select a conversation to view</span>
                  </div>
                )}
                {/* No header to sit in while the pane is idle — park it top-right. */}
                {!selectedConv && <PaneModeMenu pane={preview} label="Reading pane" className={styles.previewModeButton} />}
              </section>
              )}
              {preview.strip && <PaneStrip pane={preview} icon="envelope.open" label="Reading pane" />}
              </div>
            </div>
          ) : (
            /* ═══ GRID VIEW — stream + Eisenhower matrix ═══ */
            <>
              <div className={styles.railHeader}>
                <span className={styles.railLabel}>
                  {priorityFilter ? priorityFilter.label : 'Incoming'}
                </span>
                <span className={styles.railCount}>{conversations.length}</span>
                <div className={styles.railDivider} />
              </div>

              <div className={styles.stream} onScroll={handleStreamScroll}>
                <AnimatePresence initial={false}>
                  {(unreadOnly ? conversations.filter(c => !c.read) : conversations).map(conv => (
                    <EmailCard
                      key={conv.id}
                      conversation={conv}
                      onClick={handleCardClick}
                      onContextMenu={handleRowContextMenu}
                      onHover={handleCardHover}
                      onHoverEnd={handleCardHoverEnd}
                      onQuickAction={handleQuickAction}
                      onForward={handleForward}
                    />
                  ))}
                </AnimatePresence>
              </div>

              <div className={styles.matrixWrap}>
                <EisenhowerMatrix
                  conversations={allConversations}
                  onCardClick={handleCardClick}
                  onContextMenu={handleRowContextMenu}
                  onHover={handleCardHover}
                  onHoverEnd={handleCardHoverEnd}
                  onQuickAction={handleQuickAction}
                  onForward={handleForward}
                  isDragging={!!activeDragId}
                />
              </div>
            </>
          )}
        </div>
        <LorePanel dispatch={loreDispatch} onOpen={handleLoreOpen} />
      </div>

      <TouchStrip />

      {/* Drag overlay */}
      <DragOverlay>
        {activeDragConv ? <EmailCardGhost conversation={activeDragConv} /> : null}
      </DragOverlay>

      {/* Hover preview */}
      {hoverPreview.conv && (
        <EmailPreviewPopup
          conversation={hoverPreview.conv}
          anchorRect={hoverPreview.rect}
          onClose={closePreview}
          onView={() => { closePreview(); handleCardClick(hoverPreview.conv); }}
          onArchive={() => { closePreview(); performAndAdvance(hoverPreview.conv, CONV_ACTION.ARCHIVE); }}
          onTrash={() => { closePreview(); performAndAdvance(hoverPreview.conv, CONV_ACTION.TRASH); }}
          onMarkRead={() => { closePreview(); performConversationAction(hoverPreview.conv.id, hoverPreview.conv.accountKey, hoverPreview.conv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ); }}
          onUrgent={() => { closePreview(); applyPriority(hoverPreview.conv.id, hoverPreview.conv.accountKey, !hoverPreview.conv.urgent, hoverPreview.conv.important); }}
          onImportant={() => { closePreview(); applyPriority(hoverPreview.conv.id, hoverPreview.conv.accountKey, hoverPreview.conv.urgent, !hoverPreview.conv.important); }}
          onPopupMouseEnter={handlePopupMouseEnter}
          onPopupMouseLeave={handlePopupMouseLeave}
        />
      )}

      {/* Right-click context menu */}
      <ContextMenu
        open={contextMenu.open}
        position={contextMenu.position}
        items={contextMenuItems}
        onClose={closeContextMenu}
      />

      {/* Undo toasts */}
      <UndoToast
        entries={undoToasts}
        onUndo={undoAction}
        onDismiss={dismissUndo}
      />

      {/* Modals */}
      <UnifiedPaletteActions
        defaultFrom={defaultFrom}
        onToggleView={() => handleViewModeChange(viewMode === 'grid' ? 'list' : 'grid')}
        onToggleUnread={toggleUnreadOnly}
        onNotifications={() => setNotifOpen(true)}
      />
      <NotificationPanel open={notifOpen} onClose={() => setNotifOpen(false)} />
      <AddAccountModal
        open={addAccountOpen}
        onClose={() => setAddAccountOpen(false)}
        onGmailConnected={handleAccountConnected}
        onMicrosoftConnected={handleAccountConnected}
        onConnectMx={() => navigate('/')}
      />
      <ComposePopups />
      <MessageShortcuts
        conversation={selectedConv}
        orgId={selectedRef?.providerType === 'inbox2' ? (selectedRef.orgKey || selectedRef.accountKey) : orgId}
        defaultFrom={replyFrom}
        enabled={viewMode === 'list'}
        onStatusAction={actOnSelected}
        onTriage={handleShortcutTriage}
      />
      <ShortcutsHelp open={helpOpen} onClose={() => setHelpOpen(false)} />
    </div>
    </DndContext>
    </DraftProvider>
  );
}

// What the global command palette can run while the unified inbox is open.
// Rendered inside DraftProvider so it can reach the draft context for compose.
function UnifiedPaletteActions({ defaultFrom, onToggleView, onToggleUnread, onNotifications }) {
  const { createDraft } = useDrafts();
  const fromFor = useNewComposeFrom(defaultFrom, true);
  usePaletteActions({
    compose: () => createDraft({ fromAddress: fromFor() }),
    toggleView: onToggleView,
    toggleUnread: onToggleUnread,
    refresh: () => syncManager.resyncAll().catch(() => {}),
    notifications: onNotifications,
  });
  return null;
}
