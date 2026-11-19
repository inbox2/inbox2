import { useState, useMemo, useEffect, useCallback } from 'react';
import { useNavigate, useParams, useSearchParams } from 'react-router';
import Icon from '../../components/Icon';
import Button from '../../components/Button/Button';
import Avatar from '../../components/Avatar';
import SegmentedControl from '../../components/SegmentedControl/SegmentedControl';
import FormField, { ErrorMessage } from '../../components/FormField/FormField';
import Modal from '../../components/Modal/Modal';
import DotMatrix from '../../components/DotMatrix';
import SpaceTreemap from '../../components/SpaceTreemap/SpaceTreemap';
import SpacesPaywall from '../../components/SpacesPaywall/SpacesPaywall';
import useAuth from '../../hooks/useAuth';
import useTheme from '../../hooks/useTheme';
import useSpaces from '../../hooks/useSpaces';
import useSpaceBoard from '../../hooks/useSpaceBoard';
import useOrgMembers from '../../hooks/useOrgMembers';
import useMemberActivity from '../../hooks/useMemberActivity';
import useNavigationStore from '../../stores/navigationStore';
import TeamActivity from '../../components/TeamActivity/TeamActivity';
import { isAdminRole } from '../../lib/orgRoles';
import { isRealOrgId } from '../../lib/org';
import ContextMenu from '../../components/DropdownMenu/ContextMenu';
import useManualTriage from '../../hooks/useManualTriage';
import { CONV_ACTION, REMOVAL_ACTIONS, conversationContextMenuItems, commitAction, unreadDelta } from '../../lib/conversationActions';
import useUnreadStore from '../../stores/unreadStore';

import { setConversationPriority } from '../../lib/conversationPriority';
import { isTauri } from '../../lib/tauri';
import api from '../../lib/localFirstApi';
import log from '../../lib/log';
import { spaceColor } from '../../lib/spaceColors';
import { BOARD_VIEW, BOARD_METRIC } from '../../lib/spaceBoard';
import { faceFor } from '../../lib/demoFaces';
import { spaceMetric, MOCK_SPACES, SPACE_MESSAGES } from './mockData';
import styles from './SpaceDashboard.module.css';
import { consolePath } from '../../lib/consoleHost';

/* ── Spaces Command Center in the /admin/raw bento language: charcoal panels on
 * lavender, Clash Display, yellow/violet/pink accents. Spaces shown as a
 * treemap; recent inbox messages in a light conversation list alongside. */

const METRICS = [
  { value: BOARD_METRIC.OPEN, label: 'Open items' },
  { value: BOARD_METRIC.ALL, label: 'All items' },
  { value: BOARD_METRIC.UNREAD, label: 'Unread' },
];
const VIEWS = [{ value: BOARD_VIEW.MINE, label: 'Mine' }, { value: BOARD_VIEW.TEAM, label: 'Team' }];
// Team sub-tabs: the shared mail by Space, or the per-member activity board.
const TEAM_TAB = { SPACES: 'spaces', ACTIVITY: 'activity' };
const TEAM_TABS = [{ value: TEAM_TAB.SPACES, label: 'By Space' }, { value: TEAM_TAB.ACTIVITY, label: 'Activity' }];

// `people` are { name, email } — real members resolve a Gravatar from their
// email (falling back to an initials gradient); mock-preview people have no
// email and use a deterministic demo face instead.
function AvatarStack({ people, size = 28, max = 4 }) {
  const shown = people.slice(0, max);
  const extra = people.length - max;
  return (
    <div className={styles.stack}>
      {shown.map((p) => (
        <span className={styles.stackItem} key={p.name}>
          <Avatar name={p.name} email={p.email || undefined} src={p.email ? undefined : faceFor(p.name)} size={size} />
        </span>
      ))}
      {extra > 0 && <span className={styles.stackMore}>+{extra}</span>}
    </div>
  );
}

// Push a space's colors onto an element as CSS custom properties (no inline styles).
function colorVars(color) {
  return (el) => {
    if (!el || !color) return;
    el.style.setProperty('--c-a', color.a);
    el.style.setProperty('--c-b', color.b);
    el.style.setProperty('--c-fg', color.textOn);
    el.style.setProperty('--c-grad', color.gradient);
    el.style.setProperty('--c-glow', color.glow);
  };
}

export default function SpaceDashboard() {
  const navigate = useNavigate();
  const { orgSlug } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const { organizations, refreshAccount } = useAuth();
  const { mode } = useTheme();
  const [metric, setMetric] = useState(BOARD_METRIC.OPEN);
  // 'mine' = the viewer's own mail, 'team' = the org's shared mail (with the
  // activity board as a sub-tab). Mirrored in ?view= / ?tab= so a drill-in to a
  // member feed and back restores Team › Activity (not Mine).
  const [view, setView] = useState(() => (searchParams.get('view') === BOARD_VIEW.TEAM ? BOARD_VIEW.TEAM : BOARD_VIEW.MINE));
  const [teamTab, setTeamTab] = useState(() => (searchParams.get('tab') === TEAM_TAB.ACTIVITY ? TEAM_TAB.ACTIVITY : TEAM_TAB.SPACES));
  const [create, setCreate] = useState(null);
  const activity = view === BOARD_VIEW.TEAM && teamTab === TEAM_TAB.ACTIVITY;

  // Single entry point for switching views — keeps ?view= / ?tab= in sync.
  const changeView = useCallback((nextView, nextTab = teamTab) => {
    setView(nextView);
    setTeamTab(nextTab);
    setSearchParams((prev) => {
      const p = new URLSearchParams(prev);
      if (nextView === BOARD_VIEW.TEAM) p.set('view', BOARD_VIEW.TEAM); else p.delete('view');
      if (nextView === BOARD_VIEW.TEAM && nextTab === TEAM_TAB.ACTIVITY) p.set('tab', TEAM_TAB.ACTIVITY); else p.delete('tab');
      return p;
    }, { replace: true });
  }, [setSearchParams, teamTab]);

  // ⌘/ (Ctrl+/) flips between Mine and Team.
  useEffect(() => {
    const onKey = (e) => {
      if (!(e.metaKey || e.ctrlKey) || e.key !== '/') return;
      const tag = e.target?.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || e.target?.isContentEditable) return;
      e.preventDefault();
      changeView(view === BOARD_VIEW.TEAM ? BOARD_VIEW.MINE : BOARD_VIEW.TEAM);
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [view, changeView]);

  // Real Spaces for the active org; falls back to mock on the unguarded
  // /spaces design-preview route (no org / not signed in).
  const currentOrg = organizations?.find((o) => o.slug === orgSlug || o.id === orgSlug) || organizations?.[0] || null;
  const orgId = orgSlug || organizations?.[0]?.slug || organizations?.[0]?.id;
  const { spaces, isMock, loading, reload: reloadSpaces } = useSpaces(orgId);

  // AI triage / Spaces is a paid-plan feature (the classifier is Jev, TypeSafe's triage model). A
  // free-plan org sees a locked teaser — the mock-data treemap blurred behind an
  // upgrade card. Admins/owners get an "Upgrade now" CTA; members get a
  // "not on your plan" message. The unguarded /spaces design-preview (mock, no
  // real org) is never locked.
  const plan = currentOrg?.plan;
  const locked = !isMock && !!plan && plan.ai_triage === false;
  const isOrgAdmin = isAdminRole(currentOrg?.role);

  // One hook feeds the board for the chosen view + metric: every thread per
  // Space (MX over the API; on desktop in Mine also the viewer's connected
  // accounts from SQLite, which are per-viewer by design — never uploaded,
  // never on the Team board). The unguarded design-preview (no org) and a
  // locked org show the hand-authored mock instead, so nothing is fetched.
  const board = useSpaceBoard({ orgId, spaces, view, metric, enabled: !isMock && !locked });
  const hasLocal = board.hasLocal;
  const cellSpaces = isMock ? spaces : board.cells;
  const messagesBySpace = isMock ? SPACE_MESSAGES : board.rowsBySlug;

  // Optimistic overlay for strip-row context-menu actions: removals hide the
  // row, mark read/unread flips its dot. The underlying per-space fetch isn't
  // re-run — counts refresh on the next visit.
  const [rowPatches, setRowPatches] = useState({}); // id → { removed?, unread? }
  const patchedMessages = useMemo(() => {
    if (Object.keys(rowPatches).length === 0) return messagesBySpace;
    const out = {};
    for (const [k, list] of Object.entries(messagesBySpace)) {
      out[k] = list
        .filter((m) => !rowPatches[m.id]?.removed)
        .map((m) => rowPatches[m.id]?.unread !== undefined ? { ...m, unread: rowPatches[m.id].unread } : m);
    }
    return out;
  }, [messagesBySpace, rowPatches]);
  // When locked, the board (treemap + stat totals) reads off the mock teaser
  // rather than a real but empty workspace — derived once, used everywhere.
  // The footer totals are the org's own Space stats in either view.
  const boardSpaces = locked ? MOCK_SPACES : spaces;
  // Real org headcount (every member, incl. the admin/owner — not just those
  // staffed on a space). The design-preview (mock, no org) falls back to the
  // names staffed across the mock spaces.
  const orgMembers = useOrgMembers(isMock ? null : orgId);
  // Team activity board (the "Toggl" view). Only fetches when the Team view is
  // active, over the same real org. onOpen drills into a member's action feed.
  const { byMember: memberActivity, loading: activityLoading } = useMemberActivity(
    !isMock && activity ? orgId : null,
  );
  const people = useMemo(() => {
    if (orgMembers.length) {
      const seen = new Set();
      const out = [];
      for (const m of orgMembers) {
        const name = m.user?.display_name || m.user?.username || m.email_address || '?';
        if (seen.has(name)) continue;
        seen.add(name);
        out.push({ name, email: m.user?.billing_email || m.email_address || null });
      }
      return out;
    }
    return [...new Set(spaces.flatMap((s) => s.members.map((m) => m.name)))].map((name) => ({ name, email: null }));
  }, [orgMembers, spaces]);
  const totals = useMemo(() => ({
    open: boardSpaces.reduce((s, q) => s + spaceMetric(q, 'open'), 0),
    unread: boardSpaces.reduce((s, q) => s + q.unread, 0),
    unassigned: boardSpaces.reduce((s, q) => s + (q.unassigned || 0), 0),
    volume: boardSpaces.reduce((s, q) => s + q.volume, 0),
    spaces: boardSpaces.length,
    people: people.length,
  }), [boardSpaces, people]);

  const fmtK = (n) => (n >= 1000 ? `${(n / 1000).toFixed(1)}K` : String(n));

  // Drill into a space's mail: the UNIFIED inbox filtered to this Space — the
  // one view that shows both pools (MX via the spc_ key, the viewer's local
  // channels via space_slug). The unguarded design-preview just opens the inbox.
  const openSpace = (s) => {
    const slug = s?.slug || s?.id;
    if (slug && orgId && !isMock) navigate(`/${orgId}/mail?space=${encodeURIComponent(slug)}`);
    else navigate('/mail');
  };

  // Open one strip row's conversation. Local-channel rows carry an accountKey
  // and open in their account's inbox; MX rows open in the org inbox filtered
  // to the row's space, so the list the reader lands in matches the strip they
  // clicked. Both go through navigationStore (the router alone can't select a
  // conversation — conversationId lives in store state, not the URL).
  const openMessage = (m, s) => {
    const nav = useNavigationStore.getState();
    log.info('Spaces', `open strip conv=${m.id} account=${m.accountKey || 'mx'} space=${s?.key || s?.id || '?'}`);
    if (m.accountKey) {
      nav.navigateTo({ page: 'mail', accountKey: m.accountKey, conversationId: m.id });
    } else if (orgId) {
      nav.navigateTo({
        page: 'mail',
        orgSlug: orgId,
        accountKey: null,
        unified: false,
        space: s?.key || null,
        conversationId: m.id,
      });
    }
  };

  // ── Strip-row right-click menu (glass variant to match the dashboard) ──
  const [ctxMenu, setCtxMenu] = useState({ open: false, position: null, msg: null });
  const closeCtxMenu = useCallback(() => setCtxMenu({ open: false, position: null, msg: null }), []);
  const handleStripContextMenu = useCallback((m, e) => {
    e.preventDefault();
    e.stopPropagation();
    setCtxMenu({ open: true, position: { x: e.clientX, y: e.clientY }, msg: m });
  }, []);

  // Route an action to the row's channel: local rows (accountKey) through the
  // provider FFI, MX rows through the org bulk API.
  const dispatchRowAction = useCallback(async (m, action) => {
    if (m.accountKey) {
      if (!isTauri()) return;
      try {
        const { performAction } = await import('../../lib/providers/index.js');
        await performAction(m.accountKey, [m.id], action);
      } catch (e) { log.warn('Spaces', `${action} failed for ${m.id}: ${e?.message || e}`); }
    } else if (isRealOrgId(orgId)) {
      // Applied or durably queued → true; refused → false, and commitAction has
      // told the user. Either way the row patch below is already applied, so
      // report it back for the caller to undo.
      return commitAction(action, () => api.bulkConversations(orgId, [m.id], action));
    }
  }, [orgId]);

  const rowAction = useCallback((m, action) => {
    const isRemoval = REMOVAL_ACTIONS.includes(action);
    const isMark = action === CONV_ACTION.MARK_READ || action === CONV_ACTION.MARK_UNREAD;
    if (isRemoval) {
      setRowPatches((p) => ({ ...p, [m.id]: { ...p[m.id], removed: true } }));
    } else if (isMark) {
      setRowPatches((p) => ({ ...p, [m.id]: { ...p[m.id], unread: action === CONV_ACTION.MARK_UNREAD } }));
    }
    // This dashboard holds no inbox list, so nothing here re-derives the badge
    // — move it directly or it stays stale until the next cross-channel recount.
    const delta = unreadDelta(action, !!m.unread);
    if (delta) useUnreadStore.getState().adjust(m.accountKey, delta);
    dispatchRowAction(m, action).then((ok) => {
      // Refused by the server — drop the optimistic patch field so the row falls
      // back to its real state instead of showing an action that didn't happen.
      if (ok !== false) return;
      if (delta) useUnreadStore.getState().adjust(m.accountKey, -delta);
      if (!isRemoval && !isMark) return;
      setRowPatches((p) => {
        const patch = { ...p[m.id] };
        delete patch[isRemoval ? 'removed' : 'unread'];
        return { ...p, [m.id]: patch };
      });
    });
  }, [dispatchRowAction]);

  // Triage from the strip (lib/conversationPriority: provider priority locally, tags on MX).
  const rowPriority = useCallback(
    (m, key) => setConversationPriority({ id: m.id, accountKey: m.accountKey, orgId }, key),
    [orgId],
  );

  const ctxMsg = ctxMenu.msg;
  // Board rows: local ones carry accountKey (id = conversation key). The strip's
  // Space isn't on the row, so an MX row's current Space goes unchecked here.
  const ctxManualTriage = useManualTriage(ctxMsg && !isMock
    ? { id: ctxMsg.id, local: !!ctxMsg.accountKey, orgId, label: ctxMsg.label, space: null }
    : null);
  // Strip rows have no reply surface here — no onReply, so the menu opens with
  // the action set (mark/archive/spam/triage/delete).
  const ctxItems = !ctxMsg ? [] : conversationContextMenuItems(
    { id: ctxMsg.id, read: !ctxMsg.unread },
    {
      onMarkReadUnread: () => rowAction(ctxMsg, ctxMsg.unread ? CONV_ACTION.MARK_READ : CONV_ACTION.MARK_UNREAD),
      onArchive: () => rowAction(ctxMsg, CONV_ACTION.ARCHIVE),
      onSpam: () => rowAction(ctxMsg, CONV_ACTION.SPAM),
      onTrash: () => rowAction(ctxMsg, CONV_ACTION.TRASH),
      executePriority: (_ids, key) => rowPriority(ctxMsg, key),
      manualTriage: ctxManualTriage,
    },
  );

  return (
      <div className={styles.page}>
        {/* Ambient backdrop — light mode runs a subtly-animated water clip
         * (still photo poster / reduced-motion fallback); dark themes keep the
         * shared DotMatrix wallpaper. */}
        {mode === 'light' ? (
          <>
            <video
              className={styles.bgVideo}
              src="/bg-spaces-light.mp4"
              poster="/bg-spaces-light.webp"
              autoPlay
              loop
              muted
              playsInline
              disablePictureInPicture
              preload="auto"
              aria-hidden="true"
              tabIndex={-1}
            />
            <span className={styles.bgScrim} aria-hidden="true" />
          </>
        ) : (
          <DotMatrix />
        )}
        <div className={styles.shell}>
          {/* ── Spaces treemap (maximized) ── */}
          <div className={styles.board}>
            <section className={styles.treemapPanel}>
              <div className={styles.panelHead}>
                <SegmentedControl
                  className={styles.metricToggle}
                  options={VIEWS}
                  value={view}
                  onChange={(v) => changeView(v)}
                  aria-label="Whose mail"
                />
                {view === BOARD_VIEW.TEAM && (
                  <SegmentedControl
                    className={styles.metricToggle}
                    options={TEAM_TABS}
                    value={teamTab}
                    onChange={(t) => changeView(BOARD_VIEW.TEAM, t)}
                    aria-label="Team view"
                  />
                )}
                {view === BOARD_VIEW.MINE && hasLocal && (
                  <span className={styles.localHint}>
                    <Icon name="person.crop.circle" size={11} /> includes your connected accounts
                  </span>
                )}
                {!activity && (locked ? (
                  <span className={styles.lockBadge}><Icon name="lock" size={11} /> Pro</span>
                ) : (
                  <SegmentedControl className={styles.metricToggle} options={METRICS} value={metric} onChange={setMetric} aria-label="Size cells by" />
                ))}
              </div>
              <div className={styles.treemapWrap}>
                {activity ? (
                  <TeamActivity
                    members={orgMembers}
                    activityByMember={memberActivity}
                    loading={activityLoading}
                    onOpen={(memberId) => navigate(`/${orgId}/team/${memberId}`)}
                    trackingEnabled={currentOrg?.activity_tracking_enabled !== false}
                    canToggle={isOrgAdmin}
                    onToggle={async (next) => {
                      try {
                        await api.updateOrg(orgId, { activity_tracking_enabled: next });
                        await refreshAccount();
                      } catch (e) { log.warn('SpaceDashboard', `toggle insights failed: ${e?.message || e}`); }
                    }}
                  />
                ) : locked ? (
                  <>
                    <div className={styles.lockedPreview} aria-hidden="true">
                      <SpaceTreemap spaces={MOCK_SPACES} metric={metric} messagesBySpace={SPACE_MESSAGES} />
                    </div>
                    <SpacesPaywall isAdmin={isOrgAdmin} onUpgrade={() => navigate(consolePath('billing'))} />
                  </>
                ) : loading && spaces.length === 0 ? (
                  <div className={styles.boardHint}>Loading spaces…</div>
                ) : !loading && spaces.length === 0 ? (
                  <div className={styles.boardHint}>No spaces yet. Create one in Settings to sort your mail.</div>
                ) : (
                  <SpaceTreemap
                    spaces={cellSpaces}
                    metric={metric}
                    messagesBySpace={patchedMessages}
                    onSelect={openSpace}
                    onOpenMessage={isMock ? undefined : openMessage}
                    onMessageContextMenu={isMock ? undefined : handleStripContextMenu}
                  />
                )}
              </div>
            </section>
          </div>

        <div className={styles.bottomRow}>
          <section className={styles.teamCard}>
            <div className={styles.teamLeft}>
              {currentOrg?.logo_url ? (
                <img className={styles.logo} src={currentOrg.logo_url} alt={currentOrg.name || 'Organization'} />
              ) : (
                <span className={styles.orgName}>{currentOrg?.name || currentOrg?.domain || 'Workspace'}</span>
              )}
              <AvatarStack people={people} size={34} max={6} />
              <div className={styles.teamMeta}>
                <span className={styles.teamNum}>{totals.people}</span>
                <span className={styles.teamLabel}>{totals.people === 1 ? 'person' : 'people'}</span>
              </div>
            </div>
            <button type="button" className={styles.addBtn} onClick={() => setCreate('space')} aria-label="Create space or invite member">
              <Icon name="plus" size={20} />
            </button>
          </section>

          <div className={styles.statCards}>
            <MStat accent="accV" icon="tray.2.fill" value={fmtK(totals.volume)} label="Messages" />
            <MStat accent="accP" icon="envelope.badge" value={fmtK(totals.unread)} label="Unread" />
            <MStat accent="accG" icon="tray.full" value={fmtK(totals.unassigned)} label="Unassigned" />
          </div>
        </div>
      </div>

        {create && (
          <CreateModal
            kind={create}
            spaces={spaces}
            orgId={isMock ? null : orgId}
            org={currentOrg}
            onSwitch={setCreate}
            onClose={() => setCreate(null)}
            onDone={() => { setCreate(null); reloadSpaces(); }}
          />
        )}

        <ContextMenu
          open={ctxMenu.open}
          position={ctxMenu.position}
          items={ctxItems}
          onClose={closeCtxMenu}
          variant="glass"
        />
      </div>
  );
}

function MStat({ accent, icon, value, label }) {
  return (
    <div className={[styles.mStat, styles[accent]].join(' ')}>
      <span className={styles.mIcon}><Icon name={icon} size={17} /></span>
      <span className={styles.mText}>
        <span className={styles.mVal}>{value}</span>
        <span className={styles.mLabel}>{label}</span>
      </span>
    </div>
  );
}

// The org's primary domain (the API's `domain` mirror): the alias suffix and
// the domain an invited teammate's mailbox lands on (`domain_ids` are Domain
// keys — never the org key).
function primaryDomain(org) {
  const domains = org?.domains || [];
  return domains.find((d) => d.name === org?.domain) || domains[0] || null;
}

const OPENNESS_OPTIONS = [{ value: 'assigned', label: 'Assigned only' }, { value: 'org', label: 'Whole domain' }];

function CreateModal({ kind, spaces, orgId, org, onSwitch, onClose, onDone }) {
  const domain = primaryDomain(org);
  const domainName = domain?.name || org?.domain || '';
  const [name, setName] = useState('');
  const [alias, setAlias] = useState('');
  const [openness, setOpenness] = useState('assigned');
  const [email, setEmail] = useState('');
  const [picked, setPicked] = useState(() => new Set());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const pickable = spaces.filter((s) => s.slug !== 'triage' && s.id !== 'triage');
  const canSubmit = !!orgId && !busy && (kind === 'space' ? !!name.trim() : !!email.trim() && !!domain);

  const togglePick = (key) => setPicked((prev) => {
    const next = new Set(prev);
    if (next.has(key)) next.delete(key); else next.add(key);
    return next;
  });

  const submit = async () => {
    if (!canSubmit) return;
    setBusy(true);
    setError(null);
    try {
      if (kind === 'space') {
        await api.createSpace(orgId, { name: name.trim(), alias_local: alias.trim() || undefined, openness });
      } else {
        const { invites } = await api.inviteMx({ email: email.trim(), role: 'member', domain_ids: [domain.id] });
        const membershipKey = invites?.[0]?.id;
        // No invite-time space assignment in the API: staff the new membership
        // onto each picked space through the space-membership list.
        if (membershipKey) {
          for (const s of pickable.filter((sp) => picked.has(sp.key))) {
            const keys = s.members.map((m) => m.key).filter(Boolean);
            if (!keys.includes(membershipKey)) keys.push(membershipKey);
            await api.updateSpace(orgId, s.key, { members: keys });
          }
        }
      }
      onDone();
    } catch (e) {
      log.warn('SpaceDashboard', `${kind === 'space' ? 'Create space' : 'Invite'} failed: ${e?.message || e}`);
      setError(e?.message || (kind === 'space' ? "Couldn't create the space." : "Couldn't send the invite."));
      setBusy(false);
    }
  };

  return (
    <Modal open onClose={onClose} className={styles.modal} aria-label={kind === 'space' ? 'New space' : 'Invite member'}>
      <div className={styles.createTabs}>
        <button type="button" className={[styles.createTab, kind === 'space' ? styles.createTabOn : ''].join(' ')} onClick={() => onSwitch('space')}>
          <Icon name="square.grid.2x2" size={14} /> New space
        </button>
        <button type="button" className={[styles.createTab, kind === 'member' ? styles.createTabOn : ''].join(' ')} onClick={() => onSwitch('member')}>
          <Icon name="person.badge.plus" size={14} /> Invite member
        </button>
      </div>

      <form className={styles.createBody} onSubmit={(e) => { e.preventDefault(); submit(); }}>
        {kind === 'space' ? (
          <>
            <FormField label="Space name" placeholder="e.g. Partnerships" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
            <FormField
              label="Alias address"
              placeholder={name.trim() ? name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-') : 'partnerships'}
              hint={domainName ? `@${domainName}` : 'Optional'}
              value={alias}
              onChange={(e) => setAlias(e.target.value)}
            />
            <FormField label="Visibility">
              <SegmentedControl options={OPENNESS_OPTIONS} value={openness} onChange={setOpenness} aria-label="Visibility" />
            </FormField>
            <p className={styles.createHint}><Icon name="sparkles" size={11} /> Jev sorts incoming mail into this space.</p>
          </>
        ) : (
          <>
            <FormField label="Email to invite" type="email" placeholder="teammate@example.com" value={email} onChange={(e) => setEmail(e.target.value)} autoFocus />
            {pickable.length > 0 && (
              <FormField label="Add to spaces">
                <div className={styles.chipPick} role="group" aria-label="Add to spaces">
                  {pickable.map((s) => (
                    <SpaceChip key={s.id} name={s.name} color={spaceColor(s.id)} checked={picked.has(s.key)} onToggle={() => togglePick(s.key)} />
                  ))}
                </div>
              </FormField>
            )}
            <p className={styles.createHint}>
              <Icon name="globe" size={11} />
              {domainName ? `They get an inbox2 mailbox on ${domainName} and see assigned spaces as tabs.` : 'Add a domain to this team first.'}
            </p>
          </>
        )}
        <ErrorMessage>{error}</ErrorMessage>
      </form>

      <div className={styles.createActions}>
        <Button variant="secondary" className={styles.createCancel} onClick={onClose} disabled={busy}>Cancel</Button>
        <Button className={styles.createPrimary} onClick={submit} disabled={!canSubmit}>
          {busy ? 'Working…' : kind === 'space' ? 'Create space' : 'Send invite'}
        </Button>
      </div>
    </Modal>
  );
}

function SpaceChip({ name, color, checked, onToggle }) {
  return (
    <button type="button" ref={colorVars(color)} className={[styles.spaceChip, checked ? styles.spaceChipOn : ''].join(' ')} role="checkbox" aria-checked={checked} onClick={onToggle}>
      <span className={styles.spaceChipDot} />
      {name}
    </button>
  );
}
