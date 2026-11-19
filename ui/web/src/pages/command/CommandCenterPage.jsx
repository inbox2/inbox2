import { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useParams, useNavigate } from 'react-router';
import ForceGraph2D from 'react-force-graph-2d';
import { forceRadial } from 'd3-force-3d';
import useAuth from '../../hooks/useAuth';
import useTheme from '../../hooks/useTheme';
import useAccounts from '../../hooks/useAccounts';
import useExplorerGraph, { useEntityGraph } from '../../hooks/useExplorerGraph';
import { loadBrand } from '../../hooks/useBrand';
import { LORE_PATH } from '../../components/Lore/openItem';
import useExplorerStore from '../../stores/explorerStore';
import usePanelResize from '../../hooks/usePanelResize';
import useDebounce from '../../hooks/useDebounce';
import useCenterZoom from '../../hooks/useCenterZoom';
import useContainerSize from '../../hooks/useContainerSize';
import {
  getThemeColors, paintNode as paintNodePure,
  nodePointerAreaPaint, paintLink as paintLinkPure, trendPct,
} from '../../lib/explorerPaint';
import { resolveWorkspace } from '../../lib/workspace';
import { displayName as formatName } from '../../lib/emailAddress';
import relativeTime from '../../lib/relativeTime';
import api from '../../lib/localFirstApi';
import { isTauri } from '../../lib/tauri';
import { shortcutHint } from '../../lib/shortcuts';
import { ACTIVE_ACCOUNT_KEY } from '../../lib/storageKeys';
import Icon from '../../components/Icon';
import NavGroup, { NavItem } from '../../components/NavGroup';
import AccountSwitcher from '../../components/AccountSwitcher/AccountSwitcher';
import AddAccountModal from '../../components/AddAccountModal/AddAccountModal';
import ConnectionIndicator from '../../components/ConnectionIndicator/ConnectionIndicator';
import DotMatrix from '../../components/DotMatrix';
import layoutStyles from '../../styles/layout.module.css';
import styles from './CommandCenter.module.css';

// A KPI pill's filter predicate over a graph node (hubs never match)
function statFilterMatches(n, f) {
  if (n.type === 'channel_hub') return false;
  switch (f.kind) {
    case 'today': return (n.today || 0) > 0;
    case 'waiting24': return (n.waiting_over_24h || 0) > 0;
    case 'week': return (n.recent || 0) > 0;
    case 'busiest': return n.address === f.value;
    case 'domain': return !!n.address && n.address.endsWith(`@${f.value}`);
    default: return false;
  }
}

// Sidebar groups of the entity graph, in ontology order (lib/entityGraph).
const ENTITY_GROUPS = [
  { kind: 'organization', title: 'Organizations', icon: 'globe' },
  { kind: 'person', title: 'People', icon: 'person' },
  { kind: 'project', title: 'Projects', icon: 'folder' },
  { kind: 'product', title: 'Products & tools', icon: 'wrench.fill' },
];
const GRAPH_MODES = [
  { mode: 'entities', label: 'Entities', icon: 'point.connected' },
  { mode: 'mailboxes', label: 'Mailboxes', icon: 'tray' },
];
// Domain logos fetched per graph (each is one brand lookup server-side).
const LOGO_LIMIT = 80;
const SIDEBAR_GROUP_LIMIT = 25;

// "▲12%" / "▼8%" / "▲ new" for a week-over-week pair, or null when flat.
function trendLabel(recent, prior) {
  const pct = trendPct(recent || 0, prior || 0);
  if (pct === null || pct === 0) return null;
  if (pct === Infinity) return '▲ new';
  return `${pct > 0 ? '▲' : '▼'}${Math.round(Math.abs(pct) * 100)}%`;
}

export default function CommandCenterPage() {
  const { organizations } = useAuth();
  const { orgSlug } = useParams();
  const navigate = useNavigate();
  const { mode, themeId } = useTheme();
  const { allAccounts, addAccount } = useAccounts(organizations);

  // Transient state from Zustand store — survives tab switches
  const store = useExplorerStore();
  const searchInput = store.searchInput;
  const setSearchInput = store.setSearchInput;
  const unifiedMode = store.unifiedMode;
  const activeAccountKey = store.activeAccountKey;

  const setUnifiedMode = useCallback((v) => {
    store.setUnifiedMode(v);
    if (v) {
      localStorage.removeItem(ACTIVE_ACCOUNT_KEY);
      store.setActiveAccountKey(null);
    }
  }, [store]);

  const setActiveAccountKey = useCallback((key) => {
    store.setActiveAccountKey(key);
    if (key) localStorage.setItem(ACTIVE_ACCOUNT_KEY, key);
    else localStorage.removeItem(ACTIVE_ACCOUNT_KEY);
  }, [store]);

  const [hoveredNode, setHoveredNode] = useState(null);
  const [addAccountOpen, setAddAccountOpen] = useState(false);
  const [selectedLink, setSelectedLink] = useState(null);
  const [pairDetail, setPairDetail] = useState(null);
  const [statFilter, setStatFilter] = useState(null); // { kind, value? }
  const bodyRef = useRef(null);
  const containerRef = useRef(null);
  const graphRef = useRef(null);
  const searchRef = useRef(null);
  const colorsRef = useRef(getThemeColors());
  const sidebar = usePanelResize('inbox2_explorer_sidebar_width', 300, { min: 140, max: 420 });
  const containerSize = useContainerSize(containerRef);
  useCenterZoom(containerRef, graphRef);

  // Re-read CSS tokens when theme changes
  useEffect(() => {
    const t = setTimeout(() => { colorsRef.current = getThemeColors(); }, 50);
    return () => clearTimeout(t);
  }, [mode, themeId]);

  useEffect(() => {
    if (bodyRef.current) {
      bodyRef.current.style.setProperty('--sidebar-width', `${sidebar.width}px`);
    }
  }, [sidebar.width]);

  const searchQuery = useDebounce(searchInput, 200);

  // Command Center is org-level, but harden the lookup so a domain slug in the
  // path still resolves to its org (resolveWorkspace maps domain slug → org).
  const currentOrg = resolveWorkspace(organizations, orgSlug).org
    || organizations?.find(o => o.slug === orgSlug || o.id === orgSlug);
  const isLocalAccount = !!activeAccountKey;
  const orgId = isLocalAccount ? activeAccountKey : (currentOrg?.id || orgSlug);
  const activeUnifiedKey = activeAccountKey || orgSlug;

  // Default view: the Lore entity graph (docs/Ontology.md); "Mailboxes" keeps
  // the original mailbox ↔ contact graph one toggle away.
  const graphMode = store.graphMode;
  const entityMode = graphMode === 'entities';
  const mailboxGraph = useExplorerGraph({
    orgId, isLocalAccount, unifiedMode, allAccounts,
  });
  const entityGraph = useEntityGraph({ allAccounts, enabled: entityMode });
  const { hubImageCache } = mailboxGraph;
  const graphData = entityMode ? entityGraph.graphData : mailboxGraph.graphData;
  const loading = entityMode ? entityGraph.loading : mailboxGraph.loading;
  const stats = entityMode ? null : mailboxGraph.stats;

  // Organization/product nodes draw their domain logo (useBrand's loader);
  // each load nudges one coalesced repaint.
  const logoCache = useRef(new Map());
  const [logoTick, setLogoTick] = useState(0);
  useEffect(() => {
    if (!entityMode) return undefined;
    let live = true;
    let timer = null;
    const repaint = () => {
      if (!timer) timer = setTimeout(() => { timer = null; if (live) setLogoTick(t => t + 1); }, 250);
    };
    graphData.nodes
      .filter(n => n.email_domain && (n.kind === 'organization' || n.kind === 'product') && !logoCache.current.has(n.email_domain))
      .sort((a, b) => b.weight - a.weight)
      .slice(0, LOGO_LIMIT)
      .forEach((n) => {
        logoCache.current.set(n.email_domain, null);
        loadBrand(n.email_domain).then((brand) => {
          if (!brand?.icon) return;
          const img = new Image();
          img.onload = repaint;
          img.src = brand.icon;
          logoCache.current.set(n.email_domain, img);
        });
      });
    return () => { live = false; clearTimeout(timer); };
  }, [entityMode, graphData]);

  const handleSwitchAccount = useCallback((key) => {
    const org = organizations?.find(o => o.id === key || o.slug === key);
    if (org) {
      setActiveAccountKey(null);
      navigate(`/${org.slug}`);
    } else {
      setActiveAccountKey(key);
    }
  }, [organizations, navigate, setActiveAccountKey]);

  const handleAddAccount = async (params) => {
    if (!isTauri()) throw new Error('Connect this account from the desktop app');
    const { invoke } = await import('@tauri-apps/api/core');
    const result = await invoke('add_external_account', { request: params });
    addAccount(result);
    setActiveAccountKey(result.key);
    navigate(`/${orgSlug}`);
    window.location.reload();
  };

  const handleGmailConnected = async (accountResult) => {
    addAccount(accountResult);
    setActiveAccountKey(accountResult.key);
    navigate(`/${orgSlug}`);
    window.location.reload();
  };

  // / focuses search (Cmd+P opens the global palette — routes.jsx).
  useEffect(() => {
    const handleKey = (e) => {
      if (e.key === '/' && !e.metaKey && !e.ctrlKey && document.activeElement?.tagName !== 'INPUT') {
        e.preventDefault();
        searchRef.current?.focus();
      }
      if (e.key === 'Escape') {
        if (selectedLink) {
          setSelectedLink(null);
        } else if (statFilter) {
          setStatFilter(null);
        } else if (searchInput) {
          setSearchInput('');
          searchRef.current?.blur();
        }
      }
    };
    window.addEventListener('keydown', handleKey);
    return () => window.removeEventListener('keydown', handleKey);
  }, [searchInput, setSearchInput, selectedLink, statFilter]);

  // Configure forces once data arrives + restore saved viewport
  useEffect(() => {
    if (graphData.nodes.length > 0 && graphRef.current) {
      const fg = graphRef.current;
      fg.d3Force('charge').strength(node =>
        node.type === 'channel_hub' ? -400
        : node.type === 'mailbox' || node.kind === 'organization' ? -200 : -60
      );
      fg.d3Force('center').strength(0.05);
      fg.d3Force('link')
        .distance(link => {
          const s = typeof link.source === 'object' ? link.source : null;
          const t = typeof link.target === 'object' ? link.target : null;
          if (!s || !t) return 80;
          if (s.type === 'mailbox' && t.type === 'mailbox') return 120;
          return 80;
        })
        .strength(link => Math.min(0.2 + (link.weight || 1) * 0.05, 0.5));

      // Radial force: high-communication nodes cluster near center,
      // low-communication nodes drift toward edges
      const maxTotal = Math.max(...graphData.nodes.map(n => n.total || 0), 1);
      const maxRadius = Math.min(containerSize.width, containerSize.height) * 0.4;
      fg.d3Force('radial', forceRadial(node => {
        if (node.type === 'channel_hub') return 0;
        const t = node.total || 0;
        // Invert: high total → small radius, low total → large radius
        return maxRadius * (1 - Math.sqrt(t / maxTotal));
      }).strength(node => node.type === 'channel_hub' ? 0.8 : 0.15));

    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [graphData]);


  const handleNodeClick = useCallback((node) => {
    // Entity graph: organizations and people open their Lore page; products and
    // projects have none yet, so the camera just centres on them.
    if (node.type === 'entity') {
      if (node.kind === 'organization' && node.email_domain) navigate(LORE_PATH.ORG(node.email_domain));
      else if (node.kind === 'person' && node.address) navigate(LORE_PATH.PERSON(node.address));
      else if (graphRef.current && typeof node.x === 'number') graphRef.current.centerAt(node.x, node.y, 600);
      return;
    }
    // For hub nodes, navigate directly to that channel's inbox
    if (node.type === 'channel_hub') {
      const acctKey = node.id.replace('hub::', '');
      const acct = allAccounts.find(a => a.key === acctKey);
      if (acct?.provider_type === 'inbox2') {
        // MX domain hub → that domain's workspace path (its own slug, not the
        // dom_ account key). Fall back to the org slug if the slug is missing.
        navigate(`/${acct.domainSlug || orgSlug}/mail/inbox`);
      } else {
        const base = orgSlug ? `/${orgSlug}` : '';
        navigate(`${base}/mail/account/${acctKey}`);
      }
      return;
    }

    // Resolve the channel this node belongs to. In unified mode nodes carry
    // `accountKeys` (which channels they appear in); in single-account mode they
    // don't — so fall back to the account currently being explored. Without this
    // fallback a person clicked in a single local (Gmail/Office365) channel routed
    // to the org's Rails inbox, which holds none of that channel's offline mail →
    // an empty list.
    const acctKey = node.accountKeys?.[0] || (isLocalAccount ? activeAccountKey : null);
    const acct = acctKey ? allAccounts.find(a => a.key === acctKey) : null;
    const filterParam = node.type === 'mailbox'
      ? `?to=${encodeURIComponent(node.address)}`
      : `?from=${encodeURIComponent(node.address)}`;

    if (acct && acct.provider_type !== 'inbox2') {
      // External (local) account — route to its account-specific view
      const base = orgSlug ? `/${orgSlug}` : '';
      navigate(`${base}/mail/account/${acctKey}${filterParam}`);
    } else {
      // MX account — route to that domain's inbox with filter, keyed by the
      // domain's own slug (falling back to the current org slug).
      const slug = (acct?.provider_type === 'inbox2' ? acct.domainSlug : null) || orgSlug;
      navigate(`/${slug}/mail/inbox${filterParam}`);
    }
  }, [navigate, orgSlug, allAccounts, isLocalAccount, activeAccountKey]);

  // Link click → pair drill-down panel. Live details come from the pair
  // endpoint (MX orgs only); local/unified modes show what the link carries.
  const handleLinkClick = useCallback((link) => {
    if (entityMode) return; // the pair drill-down is a mailbox-graph feature
    const sid = typeof link.source === 'object' ? link.source.id : link.source;
    const tid = typeof link.target === 'object' ? link.target.id : link.target;
    if (String(sid).startsWith('hub::') || String(tid).startsWith('hub::')) return;
    setSelectedLink({ source: sid, target: tid, weight: link.weight, kind: link.kind });
    setPairDetail(null);
    if (!isLocalAccount && !unifiedMode && orgId) {
      api.getMailboxPair(orgId, sid, tid).then(setPairDetail).catch(() => {});
    }
  }, [orgId, isLocalAccount, unifiedMode, entityMode]);

  const openPairInMail = useCallback(() => {
    if (!selectedLink) return;
    const src = graphData.nodes.find(n => n.id === selectedLink.source);
    const tgt = graphData.nodes.find(n => n.id === selectedLink.target);
    // Filter mail by the sender side of the pair (the non-mailbox endpoint)
    const contact = (src?.type === 'mailbox' ? tgt : src)
      || { type: 'external', address: selectedLink.source, id: selectedLink.source };
    handleNodeClick(contact);
    setSelectedLink(null);
  }, [selectedLink, graphData, handleNodeClick]);

  // A KPI pill toggles a graph filter; search and pill filters are exclusive
  const toggleStatFilter = useCallback((kind, value) => {
    setStatFilter(prev => (prev && prev.kind === kind && prev.value === value) ? null : { kind, value });
    setSearchInput('');
  }, [setSearchInput]);

  // Pan the camera to a node (used by the "busiest" pill when it activates)
  const focusNode = useCallback((address) => {
    const node = graphData.nodes.find(n => n.address === address);
    if (node && graphRef.current && typeof node.x === 'number') {
      graphRef.current.centerAt(node.x, node.y, 600);
    }
  }, [graphData]);

  // Compute which nodes match the search query or the active KPI filter
  // directMatchSet = nodes whose name/address matches the text (or pill predicate)
  // visibleSet = directMatches + their immediate neighbors (shown but not highlighted)
  const { directMatchSet, visibleSet } = useMemo(() => {
    if (!searchQuery && !statFilter) return { directMatchSet: null, visibleSet: null };
    const q = searchQuery.toLowerCase();
    const direct = new Set();
    graphData.nodes.forEach(n => {
      const match = searchQuery
        ? (
          n.address?.toLowerCase().includes(q) ||
          n.email_domain?.toLowerCase().includes(q) ||
          n.name?.toLowerCase().includes(q) ||
          formatName(n.name)?.toLowerCase().includes(q)
        )
        : statFilterMatches(n, statFilter);
      if (match) direct.add(n.id);
    });
    // Neighbors of direct matches are visible but not highlighted
    const visible = new Set(direct);
    if (direct.size > 0) {
      graphData.links.forEach(l => {
        const sid = typeof l.source === 'object' ? l.source.id : l.source;
        const tid = typeof l.target === 'object' ? l.target.id : l.target;
        if (direct.has(sid)) visible.add(tid);
        if (direct.has(tid)) visible.add(sid);
      });
    }
    return { directMatchSet: direct, visibleSet: visible };
  }, [searchQuery, statFilter, graphData]);

  const matchCount = directMatchSet ? directMatchSet.size : graphData.nodes.length;

  // Canvas renderers: thin wrappers passing live component state into the pure
  // paint helpers in lib/explorerPaint.js.
  const paintNode = useCallback((node, ctx, globalScale) => {
    paintNodePure(node, ctx, globalScale, {
      colors: colorsRef.current, hoveredNode, directMatchSet, visibleSet, hubImageCache, logoCache,
    });
  // logoTick: a logo finished loading — a new callback makes the graph repaint.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hoveredNode, directMatchSet, visibleSet, hubImageCache, logoTick]);

  const paintLink = useCallback((link, ctx, globalScale) => {
    paintLinkPure(link, ctx, globalScale, {
      colors: colorsRef.current, hoveredNode, visibleSet,
    });
  }, [hoveredNode, visibleSet]);

  const mailboxNodes = graphData.nodes.filter(n => n.type === 'mailbox').sort((a, b) => a.name.localeCompare(b.name));
  const filteredMailboxNodes = directMatchSet
    ? mailboxNodes.filter(n => directMatchSet.has(n.id))
    : mailboxNodes;

  // Mailboxes with the oldest unanswered inbound conversations, worst first
  const attentionNodes = mailboxNodes
    .filter(n => n.waiting > 0 && n.oldest_waiting_at)
    .sort((a, b) => new Date(a.oldest_waiting_at) - new Date(b.oldest_waiting_at))
    .slice(0, 10);

  const entityGroups = entityMode
    ? ENTITY_GROUPS.map(g => ({
      ...g,
      nodes: graphData.nodes
        .filter(n => n.kind === g.kind && (!directMatchSet || directMatchSet.has(n.id)))
        .sort((a, b) => b.weight - a.weight)
        .slice(0, SIDEBAR_GROUP_LIMIT),
    })).filter(g => g.nodes.length > 0)
    : [];

  const weekTrend = stats ? trendLabel(stats.recent7, stats.prior7) : null;
  const domainTrend = stats?.top_external_domain ? trendLabel(stats.top_external_domain.recent, stats.top_external_domain.prior) : null;

  return (
    <>
      {/* ═══ BODY ═══ */}
      <div ref={bodyRef} className={layoutStyles.body}>
        {/* ═══ SIDEBAR ═══ */}
        <aside className={layoutStyles.sidebar}>
          {allAccounts.length > 0 && (
            <AccountSwitcher
              accounts={allAccounts}
              activeKey={unifiedMode ? null : activeUnifiedKey}
              onSwitch={(key) => { setUnifiedMode(false); handleSwitchAccount(key); }}
              onAddAccount={() => setAddAccountOpen(true)}
              onUnified={() => setUnifiedMode(true)}
              isUnified={unifiedMode}
            />
          )}
          <div className={layoutStyles.sidebarBody}>
            <div className={styles.sidebarSearch}>
              <input
                ref={searchRef}
                className={styles.sidebarSearchInput}
                placeholder="Filter… (/)"
                value={searchInput}
                onChange={(e) => { setStatFilter(null); setSearchInput(e.target.value); }}
              />
              {searchQuery && (
                <span className={styles.sidebarSearchCount}>
                  {matchCount}
                </span>
              )}
            </div>
            <div className={styles.modeToggle} role="group" aria-label="Graph">
              {GRAPH_MODES.map(({ mode: m, label, icon }) => (
                <button
                  key={m}
                  type="button"
                  aria-pressed={graphMode === m}
                  className={`${styles.statPill} ${graphMode === m ? styles.statPillActive : ''}`}
                  onClick={() => { setSelectedLink(null); setStatFilter(null); store.setGraphMode(m); }}
                >
                  <Icon name={icon} size={11} /> {label}
                </button>
              ))}
            </div>
            {entityGroups.map(g => (
              <NavGroup key={g.kind} icon={g.icon} title={g.title}>
                {g.nodes.map(n => (
                  <NavItem
                    key={n.id}
                    icon={g.icon}
                    label={n.name}
                    subtitle={n.kind === 'person' ? n.address || undefined : n.email_domain || undefined}
                    badge={String(n.weight)}
                    onClick={() => handleNodeClick(n)}
                  />
                ))}
              </NavGroup>
            ))}
            {attentionNodes.length > 0 && (
              <NavGroup icon="exclamationmark.triangle" title="Needs attention">
                {attentionNodes.map(mb => (
                  <NavItem
                    key={`attn-${mb.address}`}
                    icon="clock"
                    label={formatName(mb.name)}
                    subtitle={`${mb.waiting} waiting · oldest ${relativeTime(mb.oldest_waiting_at)}`}
                    badge={mb.waiting_over_24h > 0 ? String(mb.waiting_over_24h) : undefined}
                    onClick={() => handleNodeClick(mb)}
                  />
                ))}
              </NavGroup>
            )}
            {!entityMode && (
            <NavGroup icon="tray.fill" title="Mailboxes">
              {filteredMailboxNodes.map(mb => (
                <NavItem
                  key={mb.address}
                  icon="tray"
                  label={formatName(mb.name)}
                  subtitle={mb.address}
                  badge={mb.unread > 0 ? String(mb.unread) : undefined}
                  onClick={() => handleNodeClick(mb)}
                />
              ))}
            </NavGroup>
            )}
            <NavGroup icon="list.bullet.rectangle" title="Workflow">
              <NavItem icon="arrow.triangle.branch" label="Rules" onClick={() => navigate(orgSlug ? `/${orgSlug}/settings` : '/settings')} />
              <NavItem icon="tag" label="Tags" onClick={() => navigate(orgSlug ? `/${orgSlug}/settings` : '/settings')} />
              <NavItem icon="person.2" label="Team" onClick={() => navigate(orgSlug ? `/${orgSlug}/settings` : '/settings')} />
              <NavItem icon="gear" label="Settings" onClick={() => navigate(orgSlug ? `/${orgSlug}/settings` : '/settings')} />
            </NavGroup>
          </div>
        </aside>
        <div className={layoutStyles.resizeHandle} role="presentation" onMouseDown={sidebar.startResize} onDoubleClick={sidebar.resetWidth} />

        {/* ═══ NETWORK GRAPH ═══ */}
        <div className={styles.canvas} ref={containerRef}>
          <DotMatrix />
          {loading ? (
            <div className={styles.loadingState}>
              <Icon name="circle.grid.cross" size={32} />
              <span>{entityMode ? 'Loading entities…' : 'Loading mailboxes…'}</span>
            </div>
          ) : graphData.nodes.length === 0 ? (
            <div className={styles.emptyState}>
              <img src="/logo-cube.png" alt="inbox2" className={styles.emptyLogo} />
              <div className={styles.emptyTitle}>{entityMode ? 'No entities yet' : 'No mailboxes yet'}</div>
              <div className={styles.emptyMessage}>
                {entityMode
                  ? 'Organizations and people appear here as Lore learns them from your mail'
                  : 'Connect your domain to start receiving mail'}
              </div>
            </div>
          ) : (
            <div className={styles.graphContainer}>
              {stats && (
                <div className={styles.statsStrip}>
                  <button
                    type="button"
                    className={`${styles.statPill} ${statFilter?.kind === 'today' ? styles.statPillActive : ''}`}
                    disabled={!stats.inbound_today}
                    onClick={() => toggleStatFilter('today')}
                  >
                    <span className={styles.statValue}>{stats.inbound_today}</span> today
                  </button>
                  <button
                    type="button"
                    className={[
                      styles.statPill,
                      stats.waiting_over_24h > 0 ? styles.statPillDanger : '',
                      statFilter?.kind === 'waiting24' ? styles.statPillActive : '',
                    ].join(' ')}
                    disabled={!stats.waiting_over_24h}
                    onClick={() => toggleStatFilter('waiting24')}
                  >
                    <span className={styles.statValue}>{stats.waiting_over_24h}</span> waiting &gt;24h
                  </button>
                  <button
                    type="button"
                    className={`${styles.statPill} ${statFilter?.kind === 'week' ? styles.statPillActive : ''}`}
                    disabled={!stats.recent7}
                    onClick={() => toggleStatFilter('week')}
                  >
                    <span className={styles.statValue}>{stats.recent7}</span> this week
                    {weekTrend && (
                      <span className={weekTrend.startsWith('▲') ? styles.trendUp : styles.trendDown}>{weekTrend}</span>
                    )}
                  </button>
                  {stats.busiest && (
                    <button
                      type="button"
                      className={`${styles.statPill} ${statFilter?.kind === 'busiest' ? styles.statPillActive : ''}`}
                      onClick={() => {
                        const activating = !(statFilter?.kind === 'busiest' && statFilter.value === stats.busiest.address);
                        toggleStatFilter('busiest', stats.busiest.address);
                        if (activating) focusNode(stats.busiest.address);
                      }}
                    >
                      busiest <span className={styles.statValue}>{formatName(stats.busiest.address.split('@')[0])}</span>
                    </button>
                  )}
                  {stats.top_external_domain && (
                    <button
                      type="button"
                      className={`${styles.statPill} ${statFilter?.kind === 'domain' ? styles.statPillActive : ''}`}
                      onClick={() => toggleStatFilter('domain', stats.top_external_domain.domain)}
                    >
                      top sender <span className={styles.statValue}>{stats.top_external_domain.domain}</span>
                      {domainTrend && (
                        <span className={domainTrend.startsWith('▲') ? styles.trendUp : styles.trendDown}>{domainTrend}</span>
                      )}
                    </button>
                  )}
                </div>
              )}
              <ForceGraph2D
                ref={graphRef}
                graphData={graphData}
                width={containerSize.width}
                height={containerSize.height}
                backgroundColor="rgba(0,0,0,0)"
                nodeId="id"
                nodeCanvasObject={paintNode}
                nodePointerAreaPaint={nodePointerAreaPaint}
                linkCanvasObject={paintLink}
                linkCurvature={0.15}
                linkDirectionalParticles={0}
                onNodeClick={handleNodeClick}
                onLinkClick={handleLinkClick}
                onNodeHover={node => setHoveredNode(node?.id || null)}
                warmupTicks={60}
                cooldownTicks={30}
                onEngineStop={() => {}}
                enableZoomInteraction={false}
                enablePanInteraction={true}
                enableNodeDrag={false}
                d3AlphaDecay={0.08}
                d3VelocityDecay={0.4}
              />
              {selectedLink && (
                <div className={styles.pairPanel}>
                  <div className={styles.pairHeader}>
                    <span className={styles.pairTitle}>
                      {formatName(selectedLink.source.split('@')[0])} ↔ {formatName(selectedLink.target.split('@')[0])}
                    </span>
                    <button className={styles.pairClose} onClick={() => setSelectedLink(null)} aria-label="Close">
                      <Icon name="xmark" size={12} />
                    </button>
                  </div>
                  <div className={styles.pairAddresses}>{selectedLink.source} · {selectedLink.target}</div>
                  <div className={styles.pairStats}>
                    <span>{pairDetail ? pairDetail.total : selectedLink.weight} conversations</span>
                    {pairDetail?.unread > 0 && <span className={styles.pairUnread}>{pairDetail.unread} unread</span>}
                    {pairDetail?.last_activity_at && <span>active {relativeTime(pairDetail.last_activity_at)}</span>}
                  </div>
                  {pairDetail?.conversations?.length > 0 && (
                    <div className={styles.pairList}>
                      {pairDetail.conversations.map(c => (
                        <div key={c.id} className={styles.pairConv}>
                          <span className={styles.pairConvSubject}>{c.subject || '(no subject)'}</span>
                          <span className={styles.pairConvTime}>{relativeTime(c.updated_at)}</span>
                        </div>
                      ))}
                    </div>
                  )}
                  <button className={styles.pairOpen} onClick={openPairInMail}>Open in Mail</button>
                </div>
              )}
              <div className={styles.hintsBar}>
                <span className={styles.hint}><kbd className={styles.kbd}>/</kbd> Search</span>
                <span className={styles.hint}><kbd className={styles.kbd}>Esc</kbd> Clear</span>
                <span className={styles.hint}><kbd className={styles.kbd}>{shortcutHint('palette')}</kbd> Commands</span>
                <span className={styles.hint}><kbd className={styles.kbd}>Click</kbd> Open</span>
                <span className={styles.hint}><kbd className={styles.kbd}>Scroll</kbd> Zoom</span>
              </div>
            </div>
          )}
        </div>
      </div>

      <ConnectionIndicator />
      <AddAccountModal
        open={addAccountOpen}
        onClose={() => setAddAccountOpen(false)}
        onSubmit={handleAddAccount}
        onGmailConnected={handleGmailConnected}
        onConnectMx={() => navigate('/')}
      />
    </>
  );
}
