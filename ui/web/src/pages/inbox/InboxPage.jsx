import { lazy, Suspense, useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useParams, useNavigate, useSearchParams } from 'react-router';
import useAuth from '../../hooks/useAuth';
import useTheme from '../../hooks/useTheme';
import useNavigationStore from '../../stores/navigationStore';
import useAccountStatusStore, { needsReconnect } from '../../stores/accountStatusStore';
import useAccounts from '../../hooks/useAccounts';
import useDebounce from '../../hooks/useDebounce';
import { resolveWorkspace } from '../../lib/workspace';
import Icon from '../../components/Icon';
import Button from '../../components/Button/Button';
import ConversationList from '../../components/ConversationList';
import ConversationDetail from '../../components/ConversationDetail/ConversationDetail';
import { GhostColumn } from '../../components/Ghosts/Ghosts';
import ChannelEmptyState from '../../components/ChannelEmptyState/ChannelEmptyState';
import InboxSidebar from '../../components/InboxSidebar/InboxSidebar';
import SyncProgressBar from '../../components/SyncProgressBar/SyncProgressBar';
import InboxContextPanel from '../../components/InboxContextPanel/InboxContextPanel';
import { isRealOrgId } from '../../lib/org';
import InboxOverlays from '../../components/InboxOverlays';
import { ComposeAction } from '../../components/ComposeWidgets/ComposeWidgets';
import DotMatrix from '../../components/DotMatrix';
import ListHeader from './ListHeader';
import ReconnectBanner from './ReconnectBanner';
import MxPendingBanner from './MxPendingBanner';
// Lazy: the mini-game (board store + WebAudio synth) has no business in the
// entry chunk; it only renders after the empty-state delay.
const DropBlock = lazy(() => import('../../components/DropBlock/DropBlock'));
import useDropBlockPref from '../../lib/dropBlockPref';
import useDelayedFlag from '../../hooks/useDelayedFlag';
import ChromeBar from '../../components/Chrome/ChromeBar';
import DraftProvider from '../../hooks/DraftProvider';
import useDrafts from '../../hooks/useDrafts';
import { usePaletteActions } from '../../stores/paletteStore';
import useShortcutHelp from '../../hooks/useShortcutHelp';
import useUndoStore from '../../stores/undoStore';
import useExternalAccountSync from '../../hooks/useExternalAccountSync';
import useConversationActions from '../../hooks/useConversationActions';
import useConversationSelection from '../../hooks/useConversationSelection';
import usePendingCompose from '../../hooks/usePendingCompose';
import useSortOrder from '../../hooks/useSortOrder';
import useChromeSearch from '../../hooks/useChromeSearch';
import useInboxKeyboardNav from '../../hooks/useInboxKeyboardNav';
import useMarkRead from '../../hooks/useMarkRead';
import { conversationContextMenuItems, bulkActionMenuItems, CONV_ACTION, RESTORABLE_STATUSES, disabledFolderActions, viewFolderRole } from '../../lib/conversationActions';
import { CONV_STATUS } from '../../lib/conversationStatus';
import ConfirmDialog from '../../components/ConfirmDialog';
import api from '../../lib/localFirstApi';
import { FOLDER_ROLE } from '../../lib/folderRoles';
import { accountIconSrc } from '../../lib/providerTypes';
import { initializeInference, initializeGenerative } from '../../lib/ai';
import useInboxConversations from '../../hooks/useInboxConversations';
import useManualTriage, { manualTriageTarget } from '../../hooks/useManualTriage';
import useFolderViews from '../../hooks/useFolderViews';
import usePanelResize from '../../hooks/usePanelResize';
import useViewsAndTags from '../../hooks/useViewsAndTags';
import { filterConversations } from '../../lib/conversationFilter';
import TouchStrip from '../../components/TouchStrip/TouchStrip';
import styles from '../../styles/layout.module.css';
import { consolePath } from '../../lib/consoleHost';


export default function InboxPage() {
  const { user, organizations } = useAuth();
  const { orgSlug, accountKey: routeAccountKey } = useParams();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const mailboxFilter = searchParams.get('to');
  const senderFilter = searchParams.get('from');
  // Space filter (MX org inbox) — the spc_ key a treemap drill-down navigates to.
  const spaceFilter = searchParams.get('space');
  const { mode, themeId } = useTheme();
  const { enabled: dropBlockEnabled } = useDropBlockPref();

  // The workspace slug (/:slug/mail/...) names a specific DOMAIN — resolve it to
  // the org + domain. Domain filter narrows the org's MX pool to that domain.
  // It's suppressed when: (a) on the external-account route (no MX domain
  // context), or (b) a space filter is active — Spaces are an org-wide AI concept
  // spanning all domains, so a space drill-down shows the whole org pool.
  const { org: currentOrg, domain: slugDomain } = resolveWorkspace(organizations, orgSlug);
  const domainFilter = (routeAccountKey || spaceFilter) ? null : (slugDomain?.id || null);
  const orgId = currentOrg?.id || orgSlug;
  const orgDefaultFrom = user?.email || `${user?.username || 'me'}@${currentOrg?.domain || 'example.com'}`;

  const selectedId = useNavigationStore(s => s.conversationId);
  const [wasUnread, setWasUnread] = useState(false);
  const [activeView, setActiveView] = useState(null);
  const { views, tags } = useViewsAndTags(orgId, { activeView, setActiveView });
  const { searchQuery, searchProps } = useChromeSearch(orgSlug);
  const [labelFilters, setLabelFilters] = useState(new Map()); // key → quadrantKey
  const [selectedTags, setSelectedTags] = useState(() => new Set()); // org LABELS overlay: tag names, OR'd, AND folder
  // The Filter field. Seeded from the URL ?from=/?to= drill-down so an Explorer /
  // "view sender" jump arrives pre-filled. For external accounts this drives a
  // real SQL search (debounced → textFilter below) over from/to/subject, so the
  // field actually searches the folder instead of just narrowing loaded rows —
  // editing it re-queries rather than filtering a stale, person-locked result set.
  const [listFilter, setListFilter] = useState(senderFilter || mailboxFilter || '');
  const textFilter = useDebounce(listFilter, 200);
  const [notifOpen, setNotifOpen] = useState(false);
  const [emptyFolderConfirm, setEmptyFolderConfirm] = useState(false);
  const [emptyingFolder, setEmptyingFolder] = useState(false);
  const listBodyRef = useRef(null);

  // ── Resizable panels ──
  const bodyRef = useRef(null);
  const sidebar = usePanelResize('inbox2_sidebar_width', 200, { min: 140, max: 320 });
  const list = usePanelResize('inbox2_list_width', 340, { min: 240, max: 520 });
  const context = usePanelResize('inbox2_context_width', 280, { min: 200, max: 400, reverse: true });

  useEffect(() => {
    if (!bodyRef.current) return;
    bodyRef.current.style.setProperty('--sidebar-width', `${sidebar.width}px`);
    bodyRef.current.style.setProperty('--list-width', `${list.width}px`);
    bodyRef.current.style.setProperty('--context-width', `${context.width}px`);
  }, [sidebar.width, list.width, context.width]);

  const navIsRestoring = useNavigationStore(s => s._isRestoring);

  // ── Boot on-device AI if previously enabled ──
  useEffect(() => {
    initializeInference();
    initializeGenerative();
  }, []);

  // ── External account sync (Tauri desktop only) ──
  const {
    externalAccounts, setExternalAccounts,
    activeAccountKey,
    syncStatus, syncFolders, syncProgress, syncLogs, syncDiagnostics,
    addAccountOpen, setAddAccountOpen,
    consoleOpen, setConsoleOpen,
    syncManager: syncMgr, isActiveSyncing, handleRefresh, handleRefreshChannel,
    handleAddAccount, handleAddMetaAccount, handleGmailConnected, handleMicrosoftConnected,
    onAccountRemovedRef,
  } = useExternalAccountSync({ orgId });

  // Provider of the active external account — drives social-vs-email rendering
  // (and is needed before the data hook so it can stamp rows/detail).
  const activeAccountProvider = externalAccounts.find(a => a.key === activeAccountKey)?.provider_type;

  // ── Conversation data: list + detail loading, per-channel selection memory ──
  const {
    conversations, setConversations, listLoading,
    selectedConv, setSelectedConv,
    enrichingKeys, setEnrichingKeys,
    loadError, retry,
    loadMoreConversations, hasMoreConversations,
  } = useInboxConversations({
    activeAccountKey, activeAccountProvider, orgId, activeView, mailboxFilter, senderFilter, textFilter,
    selectedId, syncStatus, selectedTags, spaceFilter, domainFilter,
  });

  // Infinite scroll for the MX list: pull the next page once the user is within
  // a screen of the bottom, so the folder keeps going instead of ending at the
  // first page. No-ops for external channels (SQLite, not paged) and once the
  // folder is fully loaded. Client-side text filtering narrows what's loaded, so
  // keep feeding while filtering too — otherwise a filter over page 1 looks like
  // "no results" for a folder that has plenty.
  const handleListScroll = useCallback((e) => {
    if (!hasMoreConversations) return;
    const el = e.currentTarget;
    if (el.scrollHeight - el.scrollTop - el.clientHeight > el.clientHeight) return;
    loadMoreConversations();
  }, [hasMoreConversations, loadMoreConversations]);

  // Name for the active Space drill-down chip — the filtered threads all carry
  // the same space, so read it off the first one that has it.
  const activeSpaceName = useMemo(
    () => (spaceFilter ? conversations.find((c) => c.space?.id === spaceFilter)?.space?.name || null : null),
    [spaceFilter, conversations],
  );
  // Clear the space filter: drop ?space= while preserving the rest of the view.
  const clearSpaceFilter = useCallback(() => {
    useNavigationStore.getState().navigateTo({ space: null }, { replaceStack: true });
  }, []);

  // ── Folder/view derivation + folder navigation ──
  const { folderViews, systemViews, personalViews, switchView } = useFolderViews({
    activeAccountKey, activeAccountProvider, syncFolders, views, activeView, setActiveView,
    setLabelFilters, setSelectedTags, setSelectedConv, mailboxFilter, senderFilter,
    navIsRestoring, syncMgr, selectedId,
  });

  // Is the open folder the pool the tab badge counts? Only the Inbox view — and
  // the org/Meta default views, for which viewFolderRole is null — is. The badge
  // itself is counted by useChannelUnreadCounts and nudged by the action
  // dispatcher; this view no longer derives it from the list it's holding (that
  // list is one page, so the number meant something different on every screen).
  const isFolderView = !!viewFolderRole(activeView) || activeView?.name === 'All Mail';
  // The Sent folder is the one view where rows should name the recipient (the
  // from-address is always the user). Drives ConversationList's isSent.
  const isSentView = viewFolderRole(activeView) === FOLDER_ROLE.SENT;
  // When an external account is removed, clear conversation state
  useEffect(() => {
    onAccountRemovedRef.current = () => {
      setConversations([]);
      setSelectedConv(null);
    };
  }, [onAccountRemovedRef, setConversations, setSelectedConv]);

  // Seed the visible Filter field from the URL ?from=/?to= filter (Explorer
  // drill-down, "view sender"), so the active filter shows as an editable search
  // term instead of a hidden URL param. Re-syncs when the filter changes
  // (including to '' when cleared); typing in the field doesn't trigger this.
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- syncing an external system (the URL) into React state
    setListFilter(senderFilter || mailboxFilter || '');
  }, [senderFilter, mailboxFilter]);

  // Clearing the Filter field also clears the URL ?from=/?to= filter when one is
  // active, so the single visible control governs both the client-side narrowing
  // and the underlying filtered load. replaceStack: not a separate history hop.
  const clearListFilter = useCallback(() => {
    setListFilter('');
    if (senderFilter || mailboxFilter) {
      useNavigationStore.getState().navigateTo({}, { replace: true, replaceStack: true, clearFilters: true });
    }
  }, [senderFilter, mailboxFilter]);

  // URL building is centralized in NavigationManager (useNavigationStore.getState().buildUrl())
  const handleToggleLabel = useCallback((label) => {
    setLabelFilters(prev => {
      const next = new Map(prev);
      if (next.has(label.key)) next.delete(label.key);
      else next.set(label.key, label.quadrantKey);
      return next;
    });
  }, []);

  const handleToggleTag = useCallback((name) => {
    setSelectedTags(prev => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  }, []);

  const handleClearTags = useCallback(() => setSelectedTags(new Set()), []);

  const handleSwitchAccount = (key) => {
    setSelectedConv(null);
    setEnrichingKeys(new Set());
    setActiveView(null);
    setLabelFilters(new Map());
    setSelectedTags(new Set());

    const org = organizations?.find(o => o.id === key || o.slug === key);
    if (org) {
      useNavigationStore.getState().navigateTo({ orgSlug: org.slug, accountKey: null, conversationId: null });
    } else {
      useNavigationStore.getState().navigateTo({ accountKey: key, conversationId: null }, { replace: true });
    }
  };

  const activeAccount = externalAccounts.find(a => a.key === activeAccountKey);
  const defaultFrom = activeAccount?.email_address || orgDefaultFrom;
  // A new message (not a reply) goes out from the inbox being viewed: the
  // channel's account, else your address at the domain. (The unified inbox
  // remembers the last-used From instead — UnifiedInboxView.)
  const composeFrom = activeAccount?.email_address
    || (slugDomain && user?.username ? `${user.username}@${slugDomain.name}` : orgDefaultFrom);

  // Surface a reconnect banner above the list when the open channel's sign-in has
  // expired — it can't sync until re-authenticated, so guide the user there.
  const activeStatus = useAccountStatusStore(s => activeAccountKey ? s.byKey[activeAccountKey] : undefined);
  const activeNeedsReconnect = !!activeAccount && needsReconnect(activeStatus ?? activeAccount.status);
  const reconnectActive = useCallback(() => {
    if (!activeAccountKey) return;
    // Settings is org-level — use the org's primary slug, not the domain slug.
    const orgBaseSlug = currentOrg?.slug || orgSlug;
    const base = orgBaseSlug ? `/${orgBaseSlug}` : '';
    navigate(`${base}/settings?section=accounts&reconnect=${encodeURIComponent(activeAccountKey)}`);
  }, [activeAccountKey, orgSlug, currentOrg, navigate]);

  // MX-domain inbox (no channel selected): warn when the domain isn't receiving
  // mail yet — its MX/DNS records aren't verified, so nothing can arrive. Guide
  // owners/consoles to the per-domain DNS setup (regular members can't change DNS,
  // so they get the notice without the action).
  const DOMAIN_READY_STATUSES = ['verified', 'receiving_mail'];
  // On a per-domain tab, check THAT domain's status; unified falls back to the
  // org's primary-domain mirror.
  const activeDomainStatus = useMemo(() => {
    if (!domainFilter) return currentOrg?.status;
    const d = (currentOrg?.domains || []).find((x) => x.id === domainFilter);
    return d?.status || currentOrg?.status;
  }, [domainFilter, currentOrg]);
  const mxDomainPending = !activeAccountKey && !!currentOrg
    && !DOMAIN_READY_STATUSES.includes(activeDomainStatus);
  const canManageDns = ['owner', 'admin'].includes(currentOrg?.role);
  const setupDomainDns = useCallback(() => {
    // Open THIS domain's DNS (the banner is on a specific domain's inbox), keyed
    // by its own slug — not the org/default slug.
    navigate(consolePath(`domains/${slugDomain?.slug || orgSlug}?tab=dns`));
  }, [slugDomain, orgSlug, navigate]);

  const { allAccounts, reorderAccounts: handleReorderAccounts } = useAccounts(
    organizations, { externalAccounts, setExternalAccounts }
  );
  const activeUnifiedKey = activeAccountKey || domainFilter || orgSlug;
  // The account behind the current view (channel OR MX domain), for the empty-state
  // identity icon. The MX domain view has accountKey=null and is keyed by orgSlug,
  // so resolve against activeUnifiedKey (accountKey || orgSlug) over allAccounts —
  // which includes the domain — so it shows its own icon, not the generic cube.
  const activeIconAccount = allAccounts.find(a => a.key === activeUnifiedKey);

  const { helpOpen, setHelpOpen } = useShortcutHelp();
  const undoToasts = useUndoStore(s => s.toasts);
  const undoAction = useUndoStore(s => s.undo);
  const dismissUndo = useUndoStore(s => s.dismiss);

  const filtered = useMemo(
    () => filterConversations(conversations, { labelFilters, listFilter, activeAccountKey }),
    [conversations, labelFilters, listFilter, activeAccountKey],
  );

  const { sortOrder, sortMenuItems, sortLabel, sortConversations } = useSortOrder();
  const filteredConversations = useMemo(
    () => sortConversations(filtered),
    [filtered, sortConversations]
  );

  // The reading pane shows a conversation only while it belongs to the folder in
  // view. A selection can linger after its conversation leaves the folder — moved
  // or archived by a sync, or carried over from another folder (e.g. a Sent thread
  // still selected when you click Inbox). Showing that stale thread beside an empty
  // list is confusing; fall back to the empty state instead. Membership is tested
  // against the folder's `conversations`, not the search-filtered list, so typing in
  // the filter box doesn't blank the open thread.
  const selectedConvInView = useMemo(
    () => !!selectedConv && conversations.some(c => c.id === selectedConv.id),
    [selectedConv, conversations]
  );
  // Destructive toolbar actions that are redundant in the current folder
  // (Archive in Archive/Sent, both in Trash) are shown disabled.
  const folderDisabled = useMemo(() => disabledFolderActions(activeView), [activeView]);
  // The reading pane is idle whenever no conversation detail is shown — including
  // when a stale selection points at a thread that has left the folder (which
  // used to leave the pane blank instead of showing the empty state). Defer the
  // game so it doesn't flash during navigation/detail-load gaps.
  const showDropBlock = useDelayedFlag(!selectedConv || !selectedConvInView);
  // Re-key DropBlock per folder/account so switching context remounts it with a
  // fresh canvas. A running game is paused (not ended) on unmount and the paused
  // board lives in the in-memory store, so returning to an empty pane resumes it.
  const dropBlockKey = `${activeAccountKey ?? domainFilter ?? orgSlug ?? ''}:${activeView?.id ?? 'default'}`;

  // ── Multi-select + right-click context-menu state ──
  const {
    selectedIds, setSelectedIds, clearSelection,
    contextMenu, closeContextMenu,
    handleConversationClick, handleConversationContextMenu,
  } = useConversationSelection({
    orderedConversations: filteredConversations, selectedId, setWasUnread,
  });

  const { executeAction, executePriority } = useConversationActions({
    activeAccountKey, orgId, conversations, displayedConversations: filteredConversations,
    selectedId, setConversations, setSelectedConv,
    // Badge: this channel's tab key, and whether what's on screen is the pool
    // the badge counts (acting inside Spam/Trash/Archive/Sent must not move it).
    badgeKey: activeAccountKey || domainFilter || orgSlug,
    inInboxView: !isFolderView,
  });

  // "Empty folder" — permanently wipe the whole Trash/Spam folder in one shot.
  // MX/org context only (no active offline account): those channels keep their
  // own junk on the provider and are never wiped through the API. Only offered
  // when the folder actually has something to clear.
  const folderRole = viewFolderRole(activeView);
  const canEmptyFolder = !activeAccountKey
    && (folderRole === CONV_STATUS.TRASH || folderRole === CONV_STATUS.SPAM)
    && conversations.length > 0;

  const handleEmptyFolder = useCallback(async () => {
    setEmptyingFolder(true);
    try {
      await api.emptyFolder(orgId, folderRole);
      setConversations([]);
      setSelectedConv(null);
      clearSelection();
    } catch { /* a failed wipe just leaves the folder; next fetch re-shows it */ }
    finally {
      setEmptyingFolder(false);
      setEmptyFolderConfirm(false);
    }
  }, [orgId, folderRole, setConversations, setSelectedConv, clearSelection]);

  // Mark the displayed conversation read per the user's preference. executeAction
  // already routes on the active channel (local SQLite + provider writeback, or
  // the org API), so the accountKey arg is unused here.
  const markSelectedRead = useCallback(
    (id) => executeAction([id], CONV_ACTION.MARK_READ, { record: false }),
    [executeAction]
  );
  // Drive mark-read from the conversation the detail pane actually renders
  // (selectedConv), not a second lookup into the list — the two could disagree
  // during a sync reload and mark the wrong read-state.
  useMarkRead({
    conv: selectedConv ? { id: selectedConv.id, read: selectedConv.read } : null,
    markRead: markSelectedRead,
  });

  const contextMenuAction = (action) => {
    const conv = contextMenu.conv;
    if (!conv) return;
    executeAction([conv.id], action);
  };

  // Reply/Forward intent from the list context menu (selects the row first if
  // its messages aren't loaded yet, then fires once it loads).
  const requestCompose = usePendingCompose({
    selectedConv,
    onSelectConversation: (conv) => handleConversationClick(conv, 0, {}),
  });

  // Deselect the open conversation → fall back to the empty reading pane.
  // Clears both the detail (selectedConv) and the nav selection (selectedId),
  // so the list row highlight clears too.
  const deselectConversation = useCallback(() => {
    setSelectedConv(null);
    useNavigationStore.getState().navigateTo({ conversationId: null }, { replace: true, replaceStack: true });
  }, [setSelectedConv]);

  // ── Keyboard navigation ──
  const {
    keyZone, focusZone, focusMessage, focusedMsgIndex,
    handleBulkAction, handleArchive, handleTrash, hasUnreadInSelection,
  } = useInboxKeyboardNav({
    filteredConversations, selectedId, selectedConv, selectedIds,
    setSelectedIds, setWasUnread,
    clearSelection, executeAction, deselectConversation,
    switchView, activeView, folderViews, listBodyRef,
  });

  // Right-clicking inside a multi-selection shows the batch menu (acts on every
  // selected row); otherwise the single-conversation menu for the clicked row.
  const contextIsBulk = contextMenu.conv && selectedIds.size > 1 && selectedIds.has(contextMenu.conv.id);
  const contextManualTriage = useManualTriage(contextIsBulk ? null : manualTriageTarget(contextMenu.conv, orgId));
  // "Move to Inbox" is offered when the FOLDER in view is spam/trash/archived —
  // not a per-row status (a Gmail thread can sit in the inbox with an 'archived'
  // conversation status), which would wrongly offer restore on inbox rows.
  const bulkRestorable = RESTORABLE_STATUSES.includes(folderRole);
  const contextMenuItems = !contextMenu.conv
    ? []
    : contextIsBulk
      ? bulkActionMenuItems(selectedIds, {
          hasUnread: hasUnreadInSelection,
          onArchive: () => handleBulkAction(CONV_ACTION.ARCHIVE),
          onSpam: () => handleBulkAction(CONV_ACTION.SPAM),
          onTrash: () => handleBulkAction(CONV_ACTION.TRASH),
          onMarkReadUnread: () => handleBulkAction(hasUnreadInSelection ? CONV_ACTION.MARK_READ : CONV_ACTION.MARK_UNREAD),
          executePriority,
          afterAction: clearSelection,
          folderRole,
          onMoveToInbox: bulkRestorable ? () => handleBulkAction(CONV_ACTION.MOVE_TO_INBOX) : undefined,
        })
      : conversationContextMenuItems(contextMenu.conv, {
          onReply: () => requestCompose(contextMenu.conv, 'reply'),
          onReplyAll: () => requestCompose(contextMenu.conv, 'reply-all'),
          onForward: () => requestCompose(contextMenu.conv, 'forward'),
          onMarkReadUnread: () => contextMenuAction(contextMenu.conv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ),
          onArchive: () => contextMenuAction(CONV_ACTION.ARCHIVE),
          onSpam: () => contextMenuAction(CONV_ACTION.SPAM),
          onTrash: () => contextMenuAction(CONV_ACTION.TRASH),
          onMoveToInbox: () => contextMenuAction(CONV_ACTION.MOVE_TO_INBOX),
          folderRole,
          executePriority,
          manualTriage: contextManualTriage,
        });

  return (
    <DraftProvider orgId={orgId} activeAccountKey={activeAccountKey}>
    <div className={styles.app} data-theme={mode} data-theme-variant={themeId}>
      <ChromeBar
        activeTab="mail"
        activeAccountKey={activeAccountKey || orgSlug}
        accounts={allAccounts}
        onReorder={handleReorderAccounts}
        onNotifications={() => setNotifOpen(true)}
        searchProps={searchProps}
      >
        <ComposeAction defaultFrom={composeFrom} />
      </ChromeBar>

      {/* ═══ BODY ═══ */}
      <div ref={bodyRef} className={styles.body}>

        {/* ═══ SIDEBAR ═══ */}
        <InboxSidebar
          allAccounts={allAccounts} activeUnifiedKey={activeUnifiedKey}
          onSwitchAccount={handleSwitchAccount} onAddAccount={() => setAddAccountOpen(true)}
          onUnified={() => navigate(orgSlug ? `/${orgSlug}/mail` : '/mail')}
          onReorder={handleReorderAccounts}
          folderViews={folderViews} systemViews={systemViews} personalViews={personalViews}
          activeView={activeView} onSwitchView={switchView}
          onFocusZone={() => focusZone('folders')}
          activeAccountKey={activeAccountKey} tags={tags} syncFolders={syncFolders}
          orgSlug={orgSlug} onNavigateSettings={() => navigate(orgSlug ? `/${orgSlug}/settings` : '/settings')}
          syncStatus={syncStatus} activeAccount={activeAccount} onOpenConsole={() => setConsoleOpen(true)}
          onRefresh={activeAccountKey ? () => handleRefreshChannel(activeAccountKey) : handleRefresh} isSyncing={isActiveSyncing}
          activeLabelKeys={labelFilters} onToggleLabel={handleToggleLabel}
          selectedTags={selectedTags} onToggleTag={handleToggleTag} onClearTags={handleClearTags}
        />
        <div className={styles.resizeHandle} role="presentation" onMouseDown={sidebar.startResize} onDoubleClick={sidebar.resetWidth} />

        {/* ═══ CONVERSATION LIST ═══ */}
        <section className={styles.list} onMouseDownCapture={() => focusZone('list')}>
          {isActiveSyncing && <SyncProgressBar progress={syncProgress} />}
          <ListHeader
            selectedIds={selectedIds}
            clearSelection={clearSelection}
            hasUnreadInSelection={hasUnreadInSelection}
            handleBulkAction={handleBulkAction}
            executePriority={executePriority}
            activeView={activeView}
            selectedTags={selectedTags}
            canEmptyFolder={canEmptyFolder}
            onEmptyFolder={() => setEmptyFolderConfirm(true)}
            folderRole={folderRole}
            bulkRestorable={bulkRestorable}
            sortLabel={sortLabel}
            sortMenuItems={sortMenuItems}
            sortOrder={sortOrder}
          />
          <div className={styles.listSearch}>
            <div className={styles.listSearchWrap}>
              <input
                className={styles.searchInput}
                placeholder="Filter..."
                value={listFilter}
                onChange={(e) => setListFilter(e.target.value)}
              />
              {listFilter && (
                <button
                  className={styles.listSearchClear}
                  onClick={clearListFilter}
                  tabIndex={-1}
                  title="Clear filter"
                >
                  <Icon name="xmark" size={8} />
                </button>
              )}
            </div>
          </div>
          {spaceFilter && (
            <div className={styles.spaceFilterBar}>
              <Icon name="square.grid.2x2" size={12} />
              <span className={styles.spaceFilterLabel}>
                {activeSpaceName ? `Space · ${activeSpaceName}` : 'Filtered by space'}
              </span>
              <button
                type="button"
                className={styles.spaceFilterClear}
                onClick={clearSpaceFilter}
                title="Clear space filter"
                aria-label="Clear space filter"
              >
                <Icon name="xmark" size={8} />
              </button>
            </div>
          )}
          {activeNeedsReconnect && <ReconnectBanner onReconnect={reconnectActive} />}
          {mxDomainPending && (
            <MxPendingBanner
              domain={currentOrg.domain}
              canManageDns={canManageDns}
              onSetupDns={setupDomainDns}
            />
          )}
          <div ref={listBodyRef} className={styles.listBody} onScroll={handleListScroll}>
            {loadError && filteredConversations.length === 0 ? (
              <div className={styles.listEmptyWrap}>
                <div className={styles.listEmpty}>
                  <ChannelEmptyState
                    iconSrc={accountIconSrc(activeIconAccount)}
                    title="Couldn't load conversations"
                    message="Something went wrong loading this folder."
                  >
                    <Button variant="secondary" onClick={retry}>Retry</Button>
                  </ChannelEmptyState>
                </div>
              </div>
            ) : (activeAccountKey && !activeView) || listLoading ? (
              // Switching channels: ghost rows instead of the previous
              // channel's mail (which briefly looked like the wrong inbox).
              <div className={styles.listEmptyWrap}>
                <div className={styles.zeroStateGhost} aria-hidden="true">
                  <GhostColumn rows={9} />
                </div>
              </div>
            ) : filteredConversations.length === 0 ? (
              <div className={styles.listEmptyWrap}>
                {!searchQuery && !listFilter && (
                  <div className={styles.zeroStateGhost} aria-hidden="true">
                    <GhostColumn rows={9} />
                  </div>
                )}
                <div className={styles.listEmpty}>
                  <ChannelEmptyState
                    iconSrc={accountIconSrc(activeIconAccount)}
                    title={
                      searchQuery || listFilter
                        ? 'No results found'
                        : `${activeView?.name?.replace(/^label:/, '') || 'Inbox'} is empty`
                    }
                    message={
                      searchQuery || listFilter
                        ? 'No conversations match your search'
                        : 'Nothing to show here yet.'
                    }
                  />
                </div>
              </div>
            ) : (
              <ConversationList
                conversations={filteredConversations}
                selectedId={selectedId}
                selectedIds={selectedIds}
                isSent={isSentView}
                disableArchive={folderDisabled.archive}
                disableTrash={folderDisabled.trash}
                onConversationClick={handleConversationClick}
                onConversationContextMenu={handleConversationContextMenu}
                onAction={executeAction}
                onForward={(conv) => requestCompose(conv, 'forward')}
              />
            )}
          </div>
        </section>
        <div className={styles.resizeHandle} role="presentation" onMouseDown={list.startResize} onDoubleClick={list.resetWidth} />

        {/* ═══ DETAIL ═══ */}
        <section className={styles.detail} onMouseDownCapture={() => focusZone('messages')}>
          <DotMatrix />
          {selectedConv && selectedConvInView ? (
            <ConversationDetail
              conversation={selectedConv}
              defaultFrom={defaultFrom}
              orgId={orgId}
              onArchive={handleArchive}
              onTrash={handleTrash}
              disableArchive={folderDisabled.archive}
              disableTrash={folderDisabled.trash}
              folderRole={folderRole}
              onConversationAction={(action) => executeAction([selectedConv.id], action)}
              executePriority={executePriority}
              wasUnread={wasUnread}
              focusedMsgIndex={keyZone === 'messages' ? focusedMsgIndex : -1}
              onFocusMessage={focusMessage}
              enrichingKeys={enrichingKeys}
            />
          ) : dropBlockEnabled ? (
            // Show the game only once the pane has been genuinely idle for a beat —
            // otherwise it flashes during the gap between selecting/restoring a
            // conversation and its detail loading. Until then, a neutral pane.
            showDropBlock ? <Suspense fallback={<div className={styles.detailEmpty} />}><DropBlock key={dropBlockKey} iconSrc={accountIconSrc(activeIconAccount)} /></Suspense> : <div className={styles.detailEmpty} />
          ) : (
            <div className={styles.detailEmpty}>
              <img src={accountIconSrc(activeIconAccount)} alt="" className={styles.zeroStateLogo} />
              Select a conversation to view
            </div>
          )}
        </section>
        <div className={`${styles.resizeHandle} ${styles.resizeHandleContext}`} role="presentation" onMouseDown={context.startResize} onDoubleClick={context.resetWidth} />

        {/* ═══ CONTEXT SIDEBAR ═══ */}
        <aside className={styles.contextSidebar}>
          <InboxContextPanel
            conversation={selectedConvInView ? selectedConv : null}
            executePriority={executePriority}
            labelsOrgId={!activeAccountKey && isRealOrgId(orgId) ? orgId : null}
            onTagsChange={(tags) => {
              const id = selectedConv?.id;
              setSelectedConv((c) => (c && c.id === id ? { ...c, tags } : c));
              setConversations((list) => list.map((c) => (c.id === id ? { ...c, tags } : c)));
            }}
          />
        </aside>

      </div>{/* end .body */}

      <TouchStrip />

      <InboxPaletteActions
        defaultFrom={composeFrom}
        onRefresh={handleRefresh}
        onNotifications={() => setNotifOpen(true)}
      />
      <InboxOverlays
        notifications={{ open: notifOpen, onClose: () => setNotifOpen(false) }}
        addAccount={{
          open: addAccountOpen,
          onClose: () => setAddAccountOpen(false),
          onSubmit: handleAddAccount,
          onMetaSubmit: handleAddMetaAccount,
          onGmailConnected: handleGmailConnected,
          onMicrosoftConnected: handleMicrosoftConnected,
          onConnectMx: () => navigate('/'),
        }}
        syncConsole={{
          open: consoleOpen,
          onClose: () => setConsoleOpen(false),
          account: activeAccount,
          folders: syncFolders,
          logs: syncLogs,
          diagnostics: syncDiagnostics,
          // The console shows the active account — its syncing flag, not any-account's.
          syncing: isActiveSyncing,
        }}
        defaultFrom={defaultFrom}
        composeFrom={composeFrom}
        messageShortcuts={{
          conversation: selectedConv,
          orgId,
          // With rows checked, status shortcuts act on the whole selection (same
          // rule as Backspace in useInboxKeyboardNav); otherwise the open thread.
          onStatusAction: (action) => (selectedIds.size > 0
            ? handleBulkAction(action)
            : selectedConv && executeAction([selectedConv.id], action)),
          onTriage: (quadrantKey) => selectedConv && executePriority([selectedConv.id], quadrantKey),
        }}
        help={{ open: helpOpen, onClose: () => setHelpOpen(false) }}
        undo={{ entries: undoToasts, onUndo: undoAction, onDismiss: dismissUndo }}
        contextMenu={{
          open: contextMenu.open,
          position: contextMenu.position,
          items: contextMenuItems,
          onClose: closeContextMenu,
        }}
      />
      <ConfirmDialog
        open={emptyFolderConfirm}
        title={`Empty ${activeView?.name || 'folder'}?`}
        message={`Every conversation in ${activeView?.name || 'this folder'} is deleted for good.`}
        confirmLabel={emptyingFolder ? 'Emptying…' : 'Delete all'}
        cancelLabel="Cancel"
        variant="danger"
        onConfirm={handleEmptyFolder}
        onCancel={() => setEmptyFolderConfirm(false)}
      />
    </div>
    </DraftProvider>
  );
}

// What the global command palette (routes.jsx) can run while the channel view is
// open. Inside DraftProvider so compose can reach the draft context.
function InboxPaletteActions({ defaultFrom, onRefresh, onNotifications }) {
  const { createDraft } = useDrafts();
  usePaletteActions({
    compose: () => createDraft({ fromAddress: defaultFrom }),
    refresh: onRefresh,
    notifications: onNotifications,
  });
  return null;
}
