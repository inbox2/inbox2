import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Navigate, useLocation, useNavigate, useParams, useSearchParams } from 'react-router';
import useAuth from '../hooks/useAuth';
import useAccounts from '../hooks/useAccounts';
import useNavigationStore from '../stores/navigationStore';
import useUnreadStore from '../stores/unreadStore';
import useInboxConversations from '../hooks/useInboxConversations';
import useViewsAndTags from '../hooks/useViewsAndTags';
import useFolderViews from '../hooks/useFolderViews';
import useConversationActions from '../hooks/useConversationActions';
import useMarkRead from '../hooks/useMarkRead';
import { resolveWorkspace } from '../lib/workspace';
import { CONV_ACTION, disabledFolderActions, viewFolderRole } from '../lib/conversationActions';
import { FOLDER_ROLE } from '../lib/folderRoles';
import Icon from '../components/Icon';
import Spinner from '../components/Spinner';
import MxPendingBanner from '../pages/inbox/MxPendingBanner';
import MobileShell, { MobileTopBar, MobileIconButton } from './MobileShell';
import { useMobileLayout, useWideTablet, MOBILE_LAYOUT } from '../hooks/useIsPhone';
import { MOBILE_TAB, useOpenNotifications } from './mobileContext';
import MobileRow from './MobileRow';
import MobileThread from './MobileThread';
import FolderDrawer from './FolderDrawer';
import AccountSwitcher from '../components/AccountSwitcher/AccountSwitcher';
import { PROVIDER } from '../lib/providerTypes';
import styles from './MobileMail.module.css';
import { consolePath } from '../lib/consoleHost';

// Pull distance (px) that triggers a refresh, and the most the list will stretch.
const PULL_TRIGGER = 64;
const PULL_MAX = 96;
const DOMAIN_READY_STATUSES = ['verified', 'receiving_mail'];

/* The phone inbox — the apps' InboxListView: a header (☰ drawer · folder ·
 * unread count), domain chips across the top, the conversation list with swipe
 * actions, pull to refresh and infinite scroll; a tapped conversation opens full
 * screen over it. Same data layer as the desktop inbox (useInboxConversations,
 * useFolderViews, useConversationActions), so folders, actions, badges and undo
 * behave identically. URLs are the desktop ones: /:slug/mail (all domains),
 * /:domainSlug/mail/inbox (one domain), ?c=conv_… for the open thread. */
export default function MobileMail() {
  const { currentOrgSlug, organizations } = useAuth();
  const { orgSlug } = useParams();
  // /mail with no workspace in the URL: land on the user's org.
  if (!orgSlug) {
    if (currentOrgSlug) return <Navigate to={`/${currentOrgSlug}/mail`} replace />;
    if (!organizations?.length) return <Navigate to={consolePath()} replace />;
  }
  return <MobileMailScreen />;
}

function MobileMailScreen() {
  const { user, organizations, isAdmin } = useAuth();
  const { orgSlug } = useParams();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const mailboxFilter = searchParams.get('to');
  const senderFilter = searchParams.get('from');

  // From the route, not the nav store: the store only catches up with the URL
  // after the first render, and a stale value would fetch the wrong pool once.
  const { pathname } = useLocation();
  const unified = /^(\/[^/]+)?\/mail\/?$/.test(pathname);
  const selectedId = useNavigationStore((s) => s.conversationId);
  const navIsRestoring = useNavigationStore((s) => s._isRestoring);

  // /:orgSlug/mail is every domain of the org; /:domainSlug/mail/inbox is one.
  const { org: currentOrg, domain: slugDomain } = resolveWorkspace(organizations, orgSlug);
  const domainFilter = unified ? null : (slugDomain?.id || null);
  const orgId = currentOrg?.id || orgSlug;
  const defaultFrom = (!unified && slugDomain && user?.username ? `${user.username}@${slugDomain.name}` : user?.email)
    || `${user?.username || 'me'}@${slugDomain?.name || currentOrg?.domain || 'example.com'}`;

  const [activeView, setActiveView] = useState(null);
  const [, setLabelFilters] = useState(() => new Map());
  const [selectedTags, setSelectedTags] = useState(() => new Set());
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [wasUnread, setWasUnread] = useState(false);
  const { views, tags } = useViewsAndTags(orgId, { activeView, setActiveView });

  const {
    conversations, setConversations, listLoading,
    selectedConv, setSelectedConv, enrichingKeys,
    loadError, retry, loadMoreConversations, hasMoreConversations,
  } = useInboxConversations({
    activeAccountKey: null, activeAccountProvider: undefined, orgId, activeView,
    mailboxFilter, senderFilter, textFilter: '', selectedId, syncStatus: null,
    selectedTags, spaceFilter: null, domainFilter, autoSelect: false,
  });

  const { folderViews, systemViews, personalViews, switchView } = useFolderViews({
    activeAccountKey: null, activeAccountProvider: undefined, syncFolders: [], views, activeView, setActiveView,
    setLabelFilters, setSelectedTags, setSelectedConv, mailboxFilter, senderFilter,
    navIsRestoring, syncMgr: null, selectedId,
  });

  const folderRole = viewFolderRole(activeView);
  const isSentView = folderRole === FOLDER_ROLE.SENT;
  const isFolderView = !!folderRole || activeView?.name === 'All Mail';
  const folderDisabled = useMemo(() => disabledFolderActions(activeView), [activeView]);
  // Badges are counted per domain tab; the all-domains view has no tab of its own
  // to nudge (null is a no-op) — the next per-domain recount catches it up.
  const badgeKey = domainFilter || null;

  const { executeAction, executePriority } = useConversationActions({
    activeAccountKey: null, orgId, conversations, displayedConversations: conversations,
    selectedId, setConversations, setSelectedConv,
    badgeKey, inInboxView: !isFolderView, followSelection: false,
  });

  // ── Opening / closing a thread ──
  // Opening pushes a history entry (?c=), so the browser/OS back gesture closes
  // the thread. The in-app back pops that same entry when this screen pushed
  // it; on a deep link (?c= was how you arrived) it just drops the ?c=.
  // Tablet is a split view: the conversation sits beside the list, so picking
  // one swaps it in place (like the desktop reading pane) instead of stacking
  // a history entry per tap.
  const tablet = useMobileLayout() === MOBILE_LAYOUT.TABLET;
  // Landscape iPad: the folder list is pinned beside the inbox, not a drawer.
  const foldersPinned = useWideTablet();
  const pushedThread = useRef(false);
  const openConversation = useCallback((conv) => {
    setWasUnread(!conv.read);
    if (tablet) {
      useNavigationStore.getState().navigateTo({ conversationId: conv.id }, { replace: true, replaceStack: true });
      return;
    }
    pushedThread.current = true;
    useNavigationStore.getState().navigateTo({ conversationId: conv.id });
  }, [tablet]);
  // A thread closed by browser Back leaves no entry of ours to pop.
  useEffect(() => { if (!selectedId) pushedThread.current = false; }, [selectedId]);
  const closeThread = useCallback(() => {
    if (tablet) { useNavigationStore.getState().navigateTo({ conversationId: null }, { replace: true, replaceStack: true }); return; }
    if (pushedThread.current) { pushedThread.current = false; navigate(-1); }
    else useNavigationStore.getState().navigateTo({ conversationId: null }, { replace: true });
  }, [navigate, tablet]);

  const markOpenRead = useCallback(
    (id) => executeAction([id], CONV_ACTION.MARK_READ, { record: false }),
    [executeAction],
  );
  useMarkRead({
    conv: selectedConv ? { id: selectedConv.id, read: selectedConv.read } : null,
    markRead: markOpenRead,
  });

  // An action from inside the thread: removals close it (the list shows the gap
  // closing and the undo toast), the rest leave it open.
  const threadAction = useCallback((action) => {
    if (!selectedConv) return;
    executeAction([selectedConv.id], action);
    if (action !== CONV_ACTION.MARK_READ && action !== CONV_ACTION.MARK_UNREAD) closeThread();
  }, [selectedConv, executeAction, closeThread]);

  // ── List: infinite scroll + pull to refresh ──
  const listRef = useRef(null);
  const pull = useRef(null);
  const [refreshing, setRefreshing] = useState(false);
  const setPull = (px, animate) => {
    const el = listRef.current;
    if (!el) return;
    el.dataset.animate = animate ? 'true' : 'false';
    el.style.setProperty('--pull', `${px}px`);
  };
  const onScroll = useCallback((e) => {
    if (!hasMoreConversations) return;
    const el = e.currentTarget;
    if (el.scrollHeight - el.scrollTop - el.clientHeight > el.clientHeight) return;
    loadMoreConversations();
  }, [hasMoreConversations, loadMoreConversations]);
  const onTouchStart = (e) => {
    if (listRef.current?.scrollTop > 0 || refreshing) return;
    pull.current = { y0: e.touches[0].clientY, dist: 0 };
  };
  const onTouchMove = (e) => {
    if (!pull.current) return;
    const dy = e.touches[0].clientY - pull.current.y0;
    if (dy <= 0) { pull.current.dist = 0; setPull(0, false); return; }
    // Resistance: the list follows the finger at half speed, up to PULL_MAX.
    pull.current.dist = Math.min(PULL_MAX, dy / 2);
    setPull(pull.current.dist, false);
  };
  const onTouchEnd = () => {
    const dist = pull.current?.dist || 0;
    pull.current = null;
    if (dist >= PULL_TRIGGER / 2 + 8) {
      setRefreshing(true);
      setPull(44, true);
      retry();
    } else {
      setPull(0, true);
    }
  };
  // A refresh ends when the reload lands (conversations change) — or after a
  // beat, so the spinner never sticks when nothing new came back.
  useEffect(() => {
    if (!refreshing) return undefined;
    const t = setTimeout(() => { setRefreshing(false); setPull(0, true); }, 900);
    return () => clearTimeout(t);
  }, [refreshing, conversations]);

  // ── Header bits ──
  const { allAccounts } = useAccounts(organizations);
  const mxAccounts = allAccounts.filter((a) => a.provider_type === PROVIDER.INBOX2);
  const unreadByChannel = useUnreadStore((s) => s.byChannel);
  // The counts are kept per domain tab (useChannelUnreadCounts): one domain reads
  // its own, the all-domains view sums the org's.
  const unreadHere = domainFilter
    ? (unreadByChannel[domainFilter] || 0)
    : allAccounts.filter((a) => a.orgSlug === currentOrg?.slug).reduce((n, a) => n + (unreadByChannel[a.key] || 0), 0);
  const viewTitle = activeView?.name?.replace(/^label:/, '') || 'Inbox';
  const openNotifications = useOpenNotifications();

  const activeDomainStatus = domainFilter
    ? (currentOrg?.domains || []).find((d) => d.id === domainFilter)?.status || currentOrg?.status
    : currentOrg?.status;
  const mxDomainPending = !!currentOrg && !DOMAIN_READY_STATUSES.includes(activeDomainStatus);

  const switchDomain = (account) => {
    setActiveView(null);
    setSelectedTags(new Set());
    // Navigate by URL, as the desktop tab bar does: the nav store's navigateTo
    // skips a move that only changes the workspace slug (domain → domain), so
    // switching between two domains did nothing.
    if (!account || !account.domainSlug) {
      navigate(`/${account?.orgSlug || currentOrg?.slug || orgSlug}/mail`);
    } else {
      navigate(`/${account.domainSlug}/mail/inbox`);
    }
  };

  const threadOpen = !!selectedId;
  const showThread = threadOpen && selectedConv?.id === selectedId;

  const thread = showThread ? (
    <MobileThread
      embedded={tablet}
      conversation={selectedConv}
      orgId={orgId}
      defaultFrom={defaultFrom}
      folderRole={folderRole}
      wasUnread={wasUnread}
      enrichingKeys={enrichingKeys}
      disableArchive={folderDisabled.archive}
      disableTrash={folderDisabled.trash}
      onBack={closeThread}
      onAction={threadAction}
      executePriority={executePriority}
    />
  ) : (
    <div className={tablet ? styles.detailState : styles.threadLoading}>
      {!tablet && <MobileTopBar leading={<MobileIconButton icon="chevron.left" label="Back" onClick={closeThread} />} title="" />}
      <div className={styles.loading}><Spinner size={18} /></div>
    </div>
  );

  return (
    <MobileShell tab={MOBILE_TAB.INBOX} hideNav={threadOpen} composeFrom={defaultFrom} rememberLast={unified}>
      <div className={styles.columns}>
      <FolderDrawer
        pinned={foldersPinned}
        open={drawerOpen || foldersPinned}
        onClose={() => setDrawerOpen(false)}
        title={slugDomain && !unified ? slugDomain.name : (currentOrg?.name || 'Mail')}
        // Desktop's channel switcher: Unified, or one channel of any workspace.
        // inbox2-hosted channels only: this screen reads MX mail, not Gmail/IMAP.
        header={mxAccounts.length > 1 ? (
          <div className={styles.switcher}>
            <AccountSwitcher
              accounts={mxAccounts}
              activeKey={slugDomain?.id}
              isUnified={unified || !slugDomain}
              onUnified={() => { setDrawerOpen(false); switchDomain(null); }}
              onSwitch={(key) => { setDrawerOpen(false); switchDomain(mxAccounts.find((a) => a.key === key)); }}
            />
          </div>
        ) : null}
        folderViews={folderViews}
        systemViews={systemViews}
        personalViews={personalViews}
        activeView={activeView}
        // A folder opens on its list here, not on the thread last read in it.
        onSwitchView={(v) => {
          switchView(v, { restore: false });
          setDrawerOpen(false);
        }}
        tags={tags}
        selectedTags={selectedTags}
        onToggleTag={(name) => setSelectedTags((prev) => {
          const next = new Set(prev);
          if (next.has(name)) next.delete(name); else next.add(name);
          return next;
        })}
        orgSlug={currentOrg?.slug || orgSlug}
        isAdmin={isAdmin}
      />
      <div className={styles.listCol}>
      <MobileTopBar
        leading={foldersPinned ? null : <MobileIconButton icon="line.3.horizontal" label="Folders" onClick={() => setDrawerOpen(true)} aria-expanded={drawerOpen} />}
        title={viewTitle}
        subtitle={unreadHere > 0 ? `${unreadHere} unread` : (slugDomain && !unified ? slugDomain.name : currentOrg?.name)}
      >
        <MobileIconButton icon="bell" label="Notifications" onClick={openNotifications} />
      </MobileTopBar>

      {allAccounts.length > 1 && (
        <div className={styles.chips} role="tablist" aria-label="Domains">
          <Chip label="All" active={unified || !slugDomain} onClick={() => switchDomain(null)} />
          {allAccounts.map((a) => (
            <Chip
              key={a.key}
              label={a.display_name}
              icon={a.icon_url}
              count={unreadByChannel[a.key]}
              active={!unified && slugDomain?.id === a.key}
              onClick={() => switchDomain(a)}
            />
          ))}
        </div>
      )}

      {selectedTags.size > 0 && (
        <div className={styles.filterBar}>
          <Icon name="tag.fill" size={12} />
          <span className={styles.filterText}>{[...selectedTags].join(', ')}</span>
          <button type="button" className={styles.filterClear} onClick={() => setSelectedTags(new Set())} aria-label="Clear labels">
            <Icon name="xmark" size={10} />
          </button>
        </div>
      )}
      {mxDomainPending && (
        <MxPendingBanner
          domain={slugDomain?.name || currentOrg?.domain}
          canManageDns={isAdmin}
          onSetupDns={() => navigate(consolePath(`domains/${slugDomain?.slug || orgSlug}?tab=dns`))}
        />
      )}

      <div
        ref={listRef}
        className={styles.list}
        onScroll={onScroll}
        onTouchStart={onTouchStart}
        onTouchMove={onTouchMove}
        onTouchEnd={onTouchEnd}
      >
        <div className={styles.pullIndicator} aria-hidden={!refreshing}>
          {refreshing ? <Spinner size={16} /> : <Icon name="arrow.clockwise" size={15} />}
        </div>
        <div className={styles.listInner}>
          {loadError && conversations.length === 0 ? (
            <EmptyState title="Couldn't load this folder" action={{ label: 'Try again', onClick: retry }} />
          ) : listLoading ? (
            <div className={styles.loading}><Spinner size={18} /></div>
          ) : conversations.length === 0 ? (
            <EmptyState title={`${viewTitle} is empty`} message="Nothing to show here yet." />
          ) : (
            conversations.map((conv) => (
              <MobileRow
                key={conv.id}
                conv={conv}
                isSent={isSentView}
                onOpen={openConversation}
                onToggleRead={() => executeAction([conv.id], conv.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ)}
                onArchive={folderDisabled.archive ? undefined : () => executeAction([conv.id], CONV_ACTION.ARCHIVE)}
                onTrash={folderDisabled.trash ? undefined : () => executeAction([conv.id], CONV_ACTION.TRASH)}
              />
            ))
          )}
          {hasMoreConversations && conversations.length > 0 && (
            <div className={styles.loadingMore}><Spinner size={14} /></div>
          )}
        </div>
      </div>
      </div>

      {tablet && (
        <div className={styles.detailCol}>
          {threadOpen ? thread : (
            <div className={styles.detailState}>
              <Icon name="tray" size={30} />
              <p className={styles.emptyText}>Select a conversation to read it.</p>
            </div>
          )}
        </div>
      )}
      </div>


      {/* Phone: the conversation covers the list. */}
      {!tablet && threadOpen && thread}
    </MobileShell>
  );
}

function Chip({ label, icon, count, active, onClick }) {
  return (
    <button type="button" role="tab" aria-selected={active}
      className={[styles.chip, active ? styles.chipOn : ''].join(' ')} onClick={onClick}>
      {icon && <img className={styles.chipIcon} src={icon} alt="" />}
      <span className={styles.chipLabel}>{label}</span>
      {count > 0 && <span className={styles.chipCount}>{count}</span>}
    </button>
  );
}

function EmptyState({ title, message, action }) {
  return (
    <div className={styles.empty}>
      <Icon name="tray" size={28} />
      <p className={styles.emptyTitle}>{title}</p>
      {message && <p className={styles.emptyText}>{message}</p>}
      {action && <button type="button" className={styles.emptyAction} onClick={action.onClick}>{action.label}</button>}
    </div>
  );
}
