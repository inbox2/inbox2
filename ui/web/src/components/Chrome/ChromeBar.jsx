import { useEffect, useState, useMemo, useRef, useContext, useCallback } from 'react';
import { useNavigate, useParams, useSearchParams, useLocation } from 'react-router';
import { DndContext, closestCenter, PointerSensor, useSensor, useSensors } from '@dnd-kit/core';
import { SortableContext, horizontalListSortingStrategy, arrayMove } from '@dnd-kit/sortable';
import useSortableNode from '../../hooks/useSortableNode';
import { AuthContext } from '../../hooks/AuthProvider';
import useNavigationStore from '../../stores/navigationStore';
import useUnreadStore, { formatBadge } from '../../stores/unreadStore';
import useChannelUnreadCounts from '../../hooks/useChannelUnreadCounts';
import useAccountStatusStore, { needsReconnect } from '../../stores/accountStatusStore';
import useAccountStatuses from '../../hooks/useAccountStatuses';
import Icon from '../Icon';
import Tooltip from '../Tooltip';
import { ToolbarButton } from '../ToolbarGroup';
import AppSwitcher from '../AppSwitcher';
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher';
import UnifiedCubeIcon from './UnifiedCubeIcon';
import WindowControls from './WindowControls';
import { startDrag, toggleMaximizeOnDoubleClick, isTauri } from '../../lib/tauri';
import { formatShortcut, withShortcut } from '../../lib/shortcuts';
import { channelLabel, PROVIDER } from '../../lib/providerTypes';
import { focusGlobalSearch } from '../../lib/globalSearch';
import { resolveWorkspace } from '../../lib/workspace';
import useRainbowTabs, { RAINBOW_TAB_COUNT } from '../../lib/rainbowTabsPref';
import syncManager from '../../lib/sync-manager';
import { WA_PATH, useLocalWhatsAppEnabled, useWaStatus } from '../../lib/localWhatsApp';
import styles from '../../styles/layout.module.css';
import useUpdateStore from '../../stores/updateStore';

// Lore is a lead tab (rendered right after the unified cube — it's a primary
// surface), so it's not in TAIL_TABS. It took the Triage (Spaces) tab's slot;
// /spaces still routes, it just has no tab.
// Each surface gets its own house glyph (Icon.jsx "Chrome tab glyphs"); color
// stays the shared tab foreground so the tail reads as one chrome.
const TAIL_TABS = [
  { key: 'disk', icon: 'folder', label: 'Disk', path: '/disk' }, // web only for now: not on desktop
  { key: 'calendar', icon: 'calendar.today', label: 'Calendar', path: '/calendar' },
  { key: 'explorer', icon: 'point.connected', label: 'Explorer', path: '' },
];

// A channel tab that's also a dnd-kit sortable — click still navigates (the
// pointer sensor only activates past 5px), drag reorders the strip.
function SortableChannelTab({ acct, isActive, tooltip, label, className, onNavigate, children }) {
  const { ref, attributes, listeners, isDragging } = useSortableNode(acct.key);
  return (
    <Tooltip content={tooltip}>
      <button
        ref={ref}
        className={`${className}${isDragging ? ` ${styles.chromeTabDragging}` : ''}`}
        onClick={!isActive ? onNavigate : undefined}
        {...attributes}
        {...listeners}
        aria-label={label}
      >
        {children}
      </button>
    </Tooltip>
  );
}

export default function ChromeBar({ activeTab, activeAccountKey, accounts = [], onNotifications, onReorder, searchProps, children }) {
  const pendingUpdate = useUpdateStore((s) => s.update);
  const navigate = useNavigate();
  const location = useLocation();
  // useParams().orgSlug is null on the org-less /mail route family; fall back to
  // the authenticated user's current org so every tab target stays org-scoped
  // (Explorer → /:orgSlug, account tabs → /:orgSlug/mail/account/:key). Read the
  // context directly (not useAuth) so ChromeBar still renders without an AuthProvider (Storybook).
  const { orgSlug: paramOrgSlug } = useParams();
  const auth = useContext(AuthContext);
  const currentOrgSlug = auth?.currentOrgSlug || null;
  const orgSlug = paramOrgSlug || currentOrgSlug;
  // The workspace slug may name a specific domain (/:domainSlug/mail/inbox).
  // Org-level surfaces (settings/calendar/explorer/search) and the unified cube
  // are NOT domain-scoped — target the org's canonical (primary) slug so they
  // don't inherit a domain slug in the path.
  const resolvedOrg = resolveWorkspace(auth?.organizations, orgSlug).org;
  const orgPrimarySlug = resolvedOrg?.slug || orgSlug;
  const unreadByChannel = useUnreadStore(s => s.byChannel);
  // Combined unread across every account/domain (MX + channels on desktop, MX-only
  // on web) — the same total that drives the OS dock badge. Surfaced on the cube.
  const totalUnread = useUnreadStore(s => s.total);
  useChannelUnreadCounts(accounts); // populate all channel badges, even unvisited ones
  const statusByKey = useAccountStatusStore(s => s.byKey);
  useAccountStatuses(accounts); // keep per-account reconnect status live

  const goBack = useNavigationStore(s => s.goBack);
  const goForward = useNavigationStore(s => s.goForward);
  const canGoBack = useNavigationStore(s => s.canGoBack());
  const canGoForward = useNavigationStore(s => s.canGoForward());

  const [isSyncing, setIsSyncing] = useState(false);
  useEffect(() => syncManager.subscribe(s => setIsSyncing(s === 'syncing')), []);
  const handleRefresh = () => { syncManager.resyncAll().catch(() => {}); };

  // A per-domain MX tab is addressed by its own slug at /:domainSlug/mail/inbox
  // (the domain occupies the path's workspace slot). The active domain is that
  // path slug; the unified cube is the bare /:orgSlug/mail route — active only
  // when there's no domain-inbox path and no external account selected.
  // Which mail tab is "current" resolves to the owning tab's OWN key
  // (activeMailAcctKey), which the highlight, ⌘[/⌘] nav and cube all key off.
  // The active-mail identifier can arrive in several forms, and both clients
  // differ — so match a tab on ANY identifier it carries rather than assuming one:
  //   • web slug-routes an MX domain (/:domainSlug/mail/inbox), no accountKey → we
  //     resolve the path slug to a Domain id;
  //   • desktop stores the domain SLUG in navAccountKey (not the id);
  //   • external channels store their acc_ key in navAccountKey.
  // acct carries all three (key = Domain id / acc_ key, domainKey = Domain id,
  // domainSlug = the slug), so key||domainKey||domainSlug covers every form. The
  // old code compared a single field and missed the desktop slug + org-slug cases,
  // so MX domain tabs never lit up.
  const onDomainInbox = activeTab === 'mail' && /\/mail\/inbox$/.test(location.pathname);
  const slugDomainId = onDomainInbox
    ? resolveWorkspace(auth?.organizations, paramOrgSlug).domain?.id || null
    : null;
  const activeMailKey = activeTab === 'mail'
    ? (activeAccountKey || slugDomainId)
    : null;
  const activeMailAcctKey = activeMailKey
    ? accounts.find(a =>
        a.key === activeMailKey || a.domainKey === activeMailKey || a.domainSlug === activeMailKey,
      )?.key || null
    : null;
  // The unified cube is active when the mail view isn't pinned to any specific
  // account/domain tab — i.e. no tab resolves from the active key.
  const isUnifiedActive = activeTab === 'mail' && !activeMailAcctKey;

  // Rainbow tabs (opt-in, Settings › Theme › Advanced): each tab gets a palette
  // colour by its position in the strip via a .rbN class; the tint lives in CSS.
  // Index 0 = cube, then accounts, then tail tabs — a left-to-right rainbow.
  const { enabled: rainbowTabs } = useRainbowTabs();
  const rbClass = (i) =>
    rainbowTabs ? ` ${styles.chromeTabRainbow} ${styles[`rb${i % RAINBOW_TAB_COUNT}`]}` : '';

  // Local WhatsApp (desktop): one tab after the channels once it's turned on in Add account.
  const showWhatsApp = useLocalWhatsAppEnabled();
  const waUnread = useWaStatus().unread;
  // Flat tab list — matches visual order: unified → spaces → channels → tail tabs
  const allTabs = useMemo(() => {
    const resolveTabPath = (tab) =>
      tab.key === 'explorer' ? (orgPrimarySlug ? `/${orgPrimarySlug}` : '/explorer')
        : tab.key === 'disk' ? tab.path // Disk is not under an org slug (lib/disk/model.js)
        : `/${orgPrimarySlug}${tab.path}`;
    return [
      { key: 'unified', navigate: () => navigate(orgPrimarySlug ? `/${orgPrimarySlug}/mail` : '/mail') },
      { key: 'lore', navigate: () => navigate('/lore') }, // not under an org slug: spans every org + channel
      ...accounts.map(acct => ({
        key: `channel:${acct.key}`,
        navigate: () => {
          if (acct.provider_type === 'inbox2') {
            // MX domain tab → that domain's own workspace path /:domainSlug/mail/inbox.
            // The single-domain/legacy fallback has no real domain slug, so it
            // falls back to the org's unified inbox.
            navigate(acct.domainKey?.startsWith('dom_') && acct.domainSlug
              ? `/${acct.domainSlug}/mail/inbox`
              : `/${acct.orgSlug || orgSlug}/mail`);
          } else {
            navigate(orgPrimarySlug ? `/${orgPrimarySlug}/mail/account/${acct.key}` : `/mail/account/${acct.key}`);
          }
        },
      })),
      ...(showWhatsApp ? [{ key: 'whatsapp', navigate: () => navigate(orgPrimarySlug ? `/${orgPrimarySlug}/${WA_PATH}` : `/${WA_PATH}`) }] : []),
      ...TAIL_TABS.filter(t => t.path != null && (t.key !== 'disk' || (orgPrimarySlug && !isTauri()))).map(tab => ({
        key: tab.key,
        navigate: () => navigate(resolveTabPath(tab)),
      })),
    ];
  }, [accounts, navigate, orgSlug, orgPrimarySlug, showWhatsApp]);

  // Lore + tail tabs (calendar/explorer) match their key directly; mail
  // with a selected account is a channel tab, otherwise the unified inbox.
  const currentTabKey = (activeTab === 'lore' && 'lore')
    || (activeTab === 'whatsapp' && 'whatsapp')
    || TAIL_TABS.find(t => t.key === activeTab)?.key
    || (activeMailAcctKey ? `channel:${activeMailAcctKey}` : 'unified');
  const currentTabIndex = allTabs.findIndex(t => t.key === currentTabKey);

  // Stable refs so the keyboard handler doesn't re-attach on every tab change
  const tabsRef = useRef(allTabs);
  const indexRef = useRef(currentTabIndex);
  useEffect(() => { tabsRef.current = allTabs; }, [allTabs]);
  useEffect(() => { indexRef.current = currentTabIndex; }, [currentTabIndex]);

  useEffect(() => {
    const handler = (e) => {
      if (!(e.metaKey || e.ctrlKey)) return;
      // In a text field, ⌘←/⌘→ is caret navigation (line start/end) — never
      // history navigation (it would yank the page out from under a composer).
      const el = e.target;
      const editable = el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
      if (e.key === 'ArrowLeft') { if (editable) return; e.preventDefault(); goBack(); return; }
      if (e.key === 'ArrowRight') { if (editable) return; e.preventDefault(); goForward(); return; }
      if (e.key === 'k') { e.preventDefault(); focusGlobalSearch(); return; }
      const tabs = tabsRef.current;
      const idx = indexRef.current;
      if (e.key === '[' && tabs.length > 0) {
        e.preventDefault();
        tabs[idx > 0 ? idx - 1 : tabs.length - 1].navigate();
        return;
      }
      if (e.key === ']' && tabs.length > 0) {
        e.preventDefault();
        tabs[idx < tabs.length - 1 ? idx + 1 : 0].navigate();
        return;
      }
      if (e.key >= '1' && e.key <= '9') {
        const target = parseInt(e.key, 10) - 1;
        if (target < tabs.length) {
          e.preventDefault();
          tabs[target].navigate();
        }
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [goBack, goForward]);

  // Modifier global shortcuts (⌘S / Ctrl+S = resync all, ⌘, / Ctrl+, = settings)
  // — mirror the toolbar buttons below. Require the platform modifier (and no
  // Alt/Shift) so they don't collide with bare single-key list nav; skipped
  // while typing.
  useEffect(() => {
    const handler = (e) => {
      if (!(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey) return;
      const tag = e.target?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || e.target?.isContentEditable) return;
      if (e.key === 's' || e.key === 'S') { if (!isTauri()) return; e.preventDefault(); syncManager.resyncAll().catch(() => {}); }
      else if (e.key === ',') { e.preventDefault(); navigate(orgPrimarySlug ? `/${orgPrimarySlug}/settings` : '/settings'); }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [navigate, orgPrimarySlug]);

  // Global search (uniform across every screen): when a page doesn't supply its
  // own bespoke searchProps, the chrome search box drives the shared results
  // route. Typing + Enter navigates to /:orgSlug/search?q=…; the value stays in
  // sync with the URL so the box reflects the active query on the results page.
  const [searchParams] = useSearchParams();
  // Seeded from the URL, and re-synced whenever `q` changes — the Filters
  // dialog rewrites the query ("emirates type:docx"), and a box still reading
  // "emirates" would be lying about what's on screen. Only a URL that HAS a
  // query writes to the box, so navigating away doesn't wipe what you typed.
  const urlQuery = searchParams.get('q') || '';
  const [globalQuery, setGlobalQuery] = useState(urlQuery);
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: follow the URL's query */
  useEffect(() => { if (urlQuery) setGlobalQuery(urlQuery); }, [urlQuery]);
  /* eslint-enable react-hooks/set-state-in-effect */
  const searchBase = orgPrimarySlug ? `/${orgPrimarySlug}/search` : '/mail/search';
  const onSearchPage = /\/search(\/|$)/.test(location.pathname);
  const effectiveSearchProps = searchProps || {
    value: globalQuery,
    onChange: (e) => setGlobalQuery(e.target.value),
    onKeyDown: (e) => {
      if (e.key !== 'Enter') return;
      const v = e.target.value.trim();
      // Enter on an emptied box = clear the search, not "search for nothing".
      if (v) navigate(`${searchBase}?q=${encodeURIComponent(v)}`);
      else effectiveSearchProps.onClear();
    },
    // Clearing returns to wherever the search was launched from (the results page
    // was pushed onto the history stack), falling back to just emptying the box.
    onClear: () => {
      setGlobalQuery('');
      if (onSearchPage && canGoBack) goBack();
    },
  };

  const navigateTab = (key) => allTabs.find(t => t.key === key)?.navigate();

  // Drag & drop tab reorder — same mechanic (and same onReorder contract) as the
  // AccountSwitcher dropdown list, horizontal instead of vertical.
  const dndSensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } })
  );
  const handleTabDragEnd = useCallback((event) => {
    const { active, over } = event;
    if (!over || active.id === over.id) return;
    const oldIndex = accounts.findIndex(a => a.key === active.id);
    const newIndex = accounts.findIndex(a => a.key === over.id);
    if (oldIndex === -1 || newIndex === -1) return;
    onReorder?.(arrayMove(accounts, oldIndex, newIndex).map(a => a.key));
  }, [accounts, onReorder]);

  // Position in allTabs maps to the ⌘1…⌘9 (Ctrl+1…Ctrl+9) shortcut for that tab
  const tabShortcut = (key) => {
    const idx = allTabs.findIndex(t => t.key === key);
    return idx >= 0 && idx < 9 ? ` (${formatShortcut(`⌘${idx + 1}`)})` : '';
  };

  const tabText = (label) => {
    const at = label.indexOf('@');
    if (at < 0) return label;
    const domain = label.slice(at);
    return accounts.filter(a => channelLabel(a).endsWith(domain)).length > 1 ? label : domain.slice(1);
  };

  return (
    <div className={styles.chrome} role="presentation" onMouseDown={startDrag} onDoubleClick={toggleMaximizeOnDoubleClick}>
      <div className={styles.chromeTabs} data-testid="chrome-tabs">
        <Tooltip content={`Unified Inbox${tabShortcut('unified')}`}>
          <button
            aria-label="Unified Inbox"
            className={`${styles.chromeTab}${isUnifiedActive ? ` ${styles.chromeTabActive}` : ''}${rbClass(0)}`}
            onClick={!isUnifiedActive ? () => navigateTab('unified') : undefined}
          >
            <UnifiedCubeIcon active={isUnifiedActive} className={styles.chromeTabLogo} />
            {/* Combined unread total (all sources) — mirrors the per-channel tab
                badge, floated into the square cube's corner. */}
            {totalUnread > 0 && (
              <span className={`${styles.chromeTabBadge} ${styles.chromeTabCubeBadge}`}>{formatBadge(totalUnread)}</span>
            )}
          </button>
        </Tooltip>

        {/* Lore — a primary surface, so it sits immediately after the unified
            cube (before the per-domain channel tabs). */}
        <Tooltip content={`Lore${tabShortcut('lore')}`}>
          <button
            aria-label="Lore"
            className={`${styles.chromeTab}${activeTab === 'lore' ? ` ${styles.chromeTabActive}` : ''}${rbClass(1)}`}
            onClick={activeTab === 'lore' ? undefined : () => navigateTab('lore')}
          >
            <Icon name="checkmark.circle" size={18} />
          </button>
        </Tooltip>

        {/* A mail channel's tab shows its domain, easier to scan; the full address
            stays when another tab shares the domain, and in the tooltip + aria-label. */}
        <DndContext sensors={dndSensors} collisionDetection={closestCenter} onDragEnd={handleTabDragEnd}>
          <SortableContext items={accounts.map(a => a.key)} strategy={horizontalListSortingStrategy}>
            {accounts.map((acct, i) => {
              // One rule for MX domains and external channels alike: the tab whose key
              // is the resolved active-mail account (see activeMailAcctKey above).
              const isActive = activeTab === 'mail' && acct.key === activeMailAcctKey;
              const unread = unreadByChannel[acct.key] || 0;
              const label = channelLabel(acct);
              const reconnect = needsReconnect(statusByKey[acct.key] ?? acct.status);
              return (
                <SortableChannelTab
                  key={acct.key}
                  acct={acct}
                  label={reconnect ? `${label}: sign-in expired` : label}
                  isActive={isActive}
                  tooltip={reconnect ? `${label}: sign-in expired. Click to reconnect.` : `${label}${tabShortcut(`channel:${acct.key}`)}`}
                  className={`${styles.chromeTab} ${styles.chromeTabChannel}${isActive ? ` ${styles.chromeTabActive}` : ''}${rbClass(2 + i)}`}
                  onNavigate={() => navigateTab(`channel:${acct.key}`)}
                >
                  <ProviderIcon type={acct.provider_type} iconUrl={acct.icon_url} avatarUrl={acct.avatar_url} name={acct.display_name || acct.email_address} size={16} />
                  <span className={styles.chromeTabChannelLabel}>{tabText(label)}</span>
                  {/* A dead sign-in takes the badge slot with a red dot — it needs the
                      user's attention more than the unread count does. */}
                  {reconnect
                    ? <span className={styles.chromeTabReauthDot} aria-label="Sign-in expired. Reconnect." />
                    : unread > 0 && <span className={styles.chromeTabBadge}>{formatBadge(unread)}</span>}
                </SortableChannelTab>
              );
            })}
          </SortableContext>
        </DndContext>

        {showWhatsApp && (
          <Tooltip content={`WhatsApp on this Mac${tabShortcut('whatsapp')}`}>
            <button
              aria-label="WhatsApp on this Mac"
              className={`${styles.chromeTab} ${styles.chromeTabChannel}${activeTab === 'whatsapp' ? ` ${styles.chromeTabActive}` : ''}${rbClass(2 + accounts.length)}`}
              onClick={activeTab === 'whatsapp' ? undefined : () => navigateTab('whatsapp')}
            >
              <ProviderIcon type={PROVIDER.WHATSAPP} name="WhatsApp" size={16} />
              <span className={styles.chromeTabChannelLabel}>WhatsApp</span>
              {waUnread > 0 && <span className={styles.chromeTabBadge}>{formatBadge(waUnread)}</span>}
            </button>
          </Tooltip>
        )}

        {TAIL_TABS.filter(t => t.key !== 'disk' || (orgPrimarySlug && !isTauri())).map((tab, j) => {
          const isTailActive = tab.key === activeTab;
          const label = tab.label || tab.key.charAt(0).toUpperCase() + tab.key.slice(1);
          return (
            <Tooltip key={tab.key} content={`${label}${tabShortcut(tab.key)}`}>
              <button
                aria-label={label}
                className={`${styles.chromeTab}${isTailActive ? ` ${styles.chromeTabActive}` : ''}${tab.path == null ? ` ${styles.chromeTabDisabled}` : ''}${rbClass(2 + accounts.length + (showWhatsApp ? 1 : 0) + j)}`}
                disabled={tab.path == null}
                onClick={tab.path != null && !isTailActive ? () => navigateTab(tab.key) : undefined}
              >
                <Icon name={tab.icon} size={18} />
              </button>
            </Tooltip>
          );
        })}
      </div>

      <div className={styles.chromeActions}>
        <button
          className={`${styles.chromeNavBtn}${canGoBack ? '' : ` ${styles.chromeNavBtnDisabled}`}`}
          onClick={canGoBack ? goBack : undefined}
          disabled={!canGoBack}
          title={withShortcut('Back', 'nav_back')}
        >
          <Icon name="chevron.left" size={14} />
        </button>
        <button
          className={`${styles.chromeNavBtn}${canGoForward ? '' : ` ${styles.chromeNavBtnDisabled}`}`}
          onClick={canGoForward ? goForward : undefined}
          disabled={!canGoForward}
          title={withShortcut('Forward', 'nav_forward')}
        >
          <Icon name="chevron.right" size={14} />
        </button>
        <div className={styles.chromeSearchWrap}>
          <input
            data-global-search
            className={styles.chromeSearch}
            placeholder={withShortcut('Search...', 'search_focus')}
            value={effectiveSearchProps?.value}
            onChange={effectiveSearchProps?.onChange}
            onKeyDown={effectiveSearchProps?.onKeyDown}
            onFocus={effectiveSearchProps?.onFocus}
            readOnly={effectiveSearchProps?.readOnly}
          />
          {effectiveSearchProps?.value && (
            <button
              className={styles.chromeSearchClear}
              onClick={effectiveSearchProps?.onClear}
              tabIndex={-1}
            >
              <Icon name="xmark" size={8} />
            </button>
          )}
        </div>
        {children}
        {/* Resync only drives local (offline) channels, which exist only in the
            desktop app — hide it on web where there's nothing to sync. */}
        {isTauri() && (
          <ToolbarButton
            icon="arrow.triangle.2.circlepath"
            variant="chrome"
            onClick={handleRefresh}
            disabled={isSyncing}
            iconClassName={isSyncing ? styles.chromeRefreshSpin : undefined}
            title={isSyncing ? 'Syncing…' : withShortcut('Resync all channels', 'sync')}
          />
        )}
        <ToolbarButton icon="bell" variant="chrome" onClick={onNotifications} title={pendingUpdate ? `Inbox2 ${pendingUpdate.version} is ready to install` : 'Notifications'}>
          {pendingUpdate && <span className={styles.chromeUpdateTag}>Update</span>}
        </ToolbarButton>
        <AppSwitcher current="mail" settingsPath={orgPrimarySlug ? `/${orgPrimarySlug}/settings` : '/settings'} />
        <WindowControls />
      </div>
    </div>
  );
}
