import { useEffect, useState } from 'react';
import { useLocation, useNavigate } from 'react-router';
import useLore from '../../hooks/useLore';
import useLorePages, { NOTES_PAGE } from '../../hooks/useLorePages';
import useWaTrackedGroups from '../../hooks/useWaTrackedGroups';
import useAuth from '../../hooks/useAuth';
import useNavigationStore from '../../stores/navigationStore';
import Icon from '../../components/Icon';
import EntityIcon from '../../components/Lore/EntityIcon';
import useSendTo from '../../components/Lore/useSendTo';
import { openLoreItem, LORE_PATH, LORE_MAIN_ID, entityPath } from '../../components/Lore/openItem';
import { LORE_BUCKET } from '../../lib/lore';
import LoreToday from './LoreToday';
import LorePeek from './LorePeek';
import LoreEntity from './LoreEntity';
import LoreWaGroup from './LoreWaGroup';
import { LoreBucket, LoreHandled, LoreHistory, LoreSearch, LorePage } from './LoreViews';
import styles from '../../components/Lore/Lore.module.css';

const SIDE_ORGS = 6;
const PEEK_OVERLAY = '(max-width: 1280px)'; // keep in step with .peek's @media in Lore.module.css
const SIDE_PEOPLE = 5;

/** /lore/<view>/<arg> → { view, arg }. One parser, so the sidebar and the body agree. */
function parseLorePath(pathname) {
  const [, , view = 'today', ...rest] = pathname.split('/');
  return { view, arg: rest.length ? decodeURIComponent(rest.join('/')) : null };
}

/**
 * Lore, full window (docs/plans/lore.md): the Notion-style workspace behind the
 * unified inbox's Today panel. Sidebar = workload views, the organizations and
 * people the open mail is about, the person's own pages, search and history;
 * the body is the selected page. One useLore instance feeds every view.
 */
export default function LoreApp() {
  const navigate = useNavigate();
  const { pathname, search } = useLocation();
  const { user, organizations } = useAuth();
  const lore = useLore();
  const pages = useLorePages();
  const tracked = useWaTrackedGroups();
  const { view, arg } = parseLorePath(pathname);
  const [query, setQuery] = useState(() => new URLSearchParams(search).get('q') || '');
  const [allOrgs, setAllOrgs] = useState(false);

  // Opening an item peeks the email beside the page — reading never leaves Lore.
  const [peek, setPeek] = useState(null);
  // Below this width the peek lies over the page (Lore.module.css): the covered page goes inert.
  const [overlay, setOverlay] = useState(() => window.matchMedia(PEEK_OVERLAY).matches);
  useEffect(() => {
    const mq = window.matchMedia(PEEK_OVERLAY);
    const on = () => setOverlay(mq.matches);
    mq.addEventListener('change', on);
    return () => mq.removeEventListener('change', on);
  }, []);
  const open = (item) => setPeek(item);
  // Out of Lore: to the last page you were on before Lore (however many Lore
  // pages deep you are), else the unified inbox of your org.
  const mailPath = organizations?.[0]?.slug ? `/${organizations[0].slug}/mail` : '/mail';
  const leave = () => {
    const { stack, index } = useNavigationStore.getState();
    const before = stack.slice(0, index).reverse().find((e) => e.page !== 'lore' && e.url);
    navigate(before?.url || mailPath);
  };
  // Back one Lore page: history when the page before was Lore, else Today.
  const back = () => {
    const { stack, index } = useNavigationStore.getState();
    if (stack[index - 1]?.page === 'lore') navigate(-1);
    else navigate(LORE_PATH.TODAY);
  };
  // A new Lore page starts at its top, not wherever the last one was scrolled to.
  useEffect(() => { document.getElementById(LORE_MAIN_ID)?.scrollTo(0, 0); }, [pathname, search]);

  // Escape leaves Lore (unless typing or a dialog is open).
  useEffect(() => {
    const onKey = (e) => {
      if (e.key !== 'Escape') return;
      if (peek) { setPeek(null); return; }
      const el = document.activeElement;
      if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
      if (document.querySelector('[data-overlay-open], [role="dialog"]')) return;
      e.preventDefault();
      leave();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  });
  const toEntity = (e) => navigate(entityPath(e));
  const sendTo = useSendTo();
  const ctx = { lore, pages, open, toEntity, navigate, sendTo: sendTo.open, reloadGroups: tracked.reload };
  const { orgs, people } = lore.entities;
  // Tracked groups stay listed with nothing open; the count is what's open in them.
  const openIn = new Map(lore.entities.groups.map((g) => [g.chatId, g.count]));
  const groups = tracked.groups.map((g) => ({ ...g, count: openIn.get(g.chatId) || 0 }));
  const waiting = lore.items.filter((i) => i.bucket === LORE_BUCKET.WAITING).length;
  const handled = lore.today.handled.reduce((n, g) => n + g.items.length, 0);

  const nav = (to, icon, label, count, active) => (
    <button type="button" className={`${styles.nav} ${active ? styles.navActive : ''}`} onClick={() => navigate(to)}>
      {typeof icon === 'string' ? <Icon name={icon} size={14} /> : icon}
      <span className={styles.navLabel}>{label}</span>
      {count > 0 && <span className={styles.navCount}>{count}</span>}
    </button>
  );

  let body;
  let crumb;
  if (view === 'group') {
    body = <LoreWaGroup key={arg} ctx={ctx} chatId={arg} />;
    crumb = 'WhatsApp groups';
  } else if (view === 'org' || view === 'person') {
    body = <LoreEntity ctx={ctx} kind={view} id={arg} />;
    crumb = view === 'org' ? 'Organizations' : 'People';
  } else if (view === 'waiting') {
    body = <LoreBucket ctx={ctx} bucket={LORE_BUCKET.WAITING} title="Waiting on others" icon="clock" />;
  } else if (view === 'handled') {
    body = <LoreHandled ctx={ctx} />;
  } else if (view === 'history') {
    body = <LoreHistory ctx={ctx} />;
  } else if (view === 'search') {
    body = <LoreSearch ctx={ctx} query={new URLSearchParams(search).get('q') || ''} />;
  } else if (view === 'page') {
    body = <LorePage ctx={ctx} id={arg} />;
    crumb = 'Pages';
  } else {
    body = <LoreToday ctx={ctx} />;
  }

  return (
    <div className={`${styles.lore} ${styles.app}`}>
      <nav className={styles.side} aria-label="Lore">
        <div className={styles.sideHead}>
          <span className={styles.workspaceMark}>{(user?.display_name || user?.username || 'L')[0].toUpperCase()}</span>
          <span className={styles.workspaceName}>{user?.display_name || user?.username || 'My'}'s Lore</span>
        </div>
        <form
          className={styles.sideSearch}
          role="search"
          onSubmit={(e) => { e.preventDefault(); if (query.trim()) navigate(LORE_PATH.SEARCH(query.trim())); }}
        >
          <input
            className={styles.search}
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search Lore"
            aria-label="Search Lore"
          />
        </form>
        <button type="button" className={styles.nav} onClick={leave}>
          <Icon name="tray" size={14} />
          <span className={styles.navLabel}>Back to mail</span>
        </button>

        <div className={styles.sideLabel}>Workload</div>
        {nav(LORE_PATH.TODAY, 'checkmark.circle', 'Today', lore.today.open, view === 'today')}
        {nav(LORE_PATH.WAITING, 'clock', 'Waiting on others', waiting, view === 'waiting')}
        {nav(LORE_PATH.HANDLED, 'archivebox', 'Handled for you', handled, view === 'handled')}
        {nav(LORE_PATH.HISTORY, 'clock.arrow.circlepath', 'History', 0, view === 'history')}

        {groups.length > 0 && <div className={styles.sideLabel}>WhatsApp groups</div>}
        {groups.map((g) => (
          <button
            key={g.chatId}
            type="button"
            className={`${styles.nav} ${styles.navSub} ${view === 'group' && Number(arg) === g.chatId ? styles.navActive : ''}`}
            onClick={() => navigate(LORE_PATH.GROUP(g.chatId))}
          >
            <EntityIcon name={g.name} kind="org" />
            <span className={styles.navLabel}>{g.name}</span>
            {g.ignored ? <span className={styles.navCount}>ignored</span> : g.count > 0 ? <span className={styles.navCount}>{g.count}</span> : !g.tracked && <span className={styles.navCount}>off</span>}
          </button>
        ))}

        {orgs.length > 0 && <div className={styles.sideLabel}>Organizations</div>}
        {(allOrgs ? orgs : orgs.slice(0, SIDE_ORGS)).map((o) => (
          <button
            key={o.domain}
            type="button"
            className={`${styles.nav} ${styles.navSub} ${view === 'org' && arg === o.domain ? styles.navActive : ''}`}
            onClick={() => navigate(LORE_PATH.ORG(o.domain))}
          >
            <EntityIcon domain={o.domain} name={o.name} />
            <span className={styles.navLabel}>{o.name}</span>
            <span className={styles.navCount}>{o.count}</span>
          </button>
        ))}
        {orgs.length > SIDE_ORGS && (
          <button type="button" className={`${styles.nav} ${styles.navSub} ${styles.navMore}`} onClick={() => setAllOrgs((v) => !v)}>
            <span className={styles.navLabel}>{allOrgs ? 'Show fewer' : `All ${orgs.length} organizations`}</span>
          </button>
        )}

        {people.length > 0 && <div className={styles.sideLabel}>People</div>}
        {people.slice(0, SIDE_PEOPLE).map((p) => (
          <button
            key={p.address}
            type="button"
            className={`${styles.nav} ${styles.navSub} ${view === 'person' && arg === p.address ? styles.navActive : ''}`}
            onClick={() => navigate(LORE_PATH.PERSON(p.address))}
          >
            <EntityIcon name={p.name} kind="person" />
            <span className={styles.navLabel}>{p.name}</span>
            <span className={styles.navCount}>{p.count}</span>
          </button>
        ))}

        <div className={styles.sideLabel}>My pages</div>
        {pages.notesId && nav(`${LORE_PATH.TODAY}#notes`, 'note.text', NOTES_PAGE, 0, false)}
        {pages.pages.map((p) => (
          <button
            key={p.id}
            type="button"
            className={`${styles.nav} ${view === 'page' && arg === p.id ? styles.navActive : ''}`}
            onClick={() => navigate(LORE_PATH.PAGE(p.id))}
          >
            <Icon name="doc" size={14} />
            <span className={styles.navLabel}>{p.name || 'Untitled page'}</span>
          </button>
        ))}
        {pages.notesId && (
          <button
            type="button"
            className={`${styles.nav} ${styles.navMore}`}
            onClick={async () => { const n = await pages.createPage(); if (n) navigate(LORE_PATH.PAGE(n.id)); }}
          >
            <Icon name="plus" size={14} />
            <span className={styles.navLabel}>Add a page</span>
          </button>
        )}
        {!pages.loading && !pages.notesId && (
          <p className={`${styles.muted} ${styles.navSub}`}>Pages need Disk on an inbox2 account.</p>
        )}
      </nav>

      <main id={LORE_MAIN_ID} tabIndex={-1} className={styles.main} inert={!!peek && overlay}>
        <div className={styles.topbar}>
          <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={leave} title="Back (Esc)">
            <Icon name="chevron.left" size={12} /> Back to mail
          </button>
          {view !== 'today' && (
            <button type="button" className={`${styles.button} ${styles.ghost}`} onClick={back}>
              <Icon name="chevron.left" size={12} /> Back
            </button>
          )}
          <span className={styles.crumb}>Lore</span>
          {crumb && <><span className={styles.crumbSep}>/</span><span className={styles.crumb}>{crumb}</span></>}
          <span className={styles.topbarRight}>
            {lore.error && <span role="status">Couldn't refresh everything — showing the last loaded data</span>}
            <button type="button" className={styles.iconButton} onClick={lore.refresh} aria-label="Refresh" title="Refresh">
              <Icon name="arrow.clockwise" size={13} />
            </button>
          </span>
        </div>
        {body}
      </main>
      {peek && (
        <LorePeek
          key={peek.uid}
          item={peek}
          lore={lore}
          onClose={() => setPeek(null)}
          onOpenInInbox={() => openLoreItem(peek, organizations)}
        />
      )}
      {sendTo.dialog}
    </div>
  );
}
