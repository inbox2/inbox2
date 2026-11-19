import { useState } from 'react';
import { useNavigate } from 'react-router';
import useAuth from '../hooks/useAuth';
import useTheme from '../hooks/useTheme';
import useDrafts from '../hooks/useDrafts';
import DraftProvider from '../hooks/DraftProvider';
import useUndoStore from '../stores/undoStore';
import { useNewComposeFrom } from '../hooks/useFromIdentities';
import Icon from '../components/Icon';
import UndoToast from '../components/UndoToast/UndoToast';
import { ComposePopups } from '../components/ComposeWidgets/ComposeWidgets';
import NotificationPanel from '../components/NotificationPanel/NotificationPanel';
import { MOBILE_TAB, MobileNotifContext, useMobileOrg } from './mobileContext';
import { useMobileLayout, MOBILE_LAYOUT } from '../hooks/useIsPhone';
import styles from './MobileShell.module.css';

/* The phone shell, mirroring the iOS/Android apps (docs/iOS-App.md): one screen
 * at a time over a floating capsule nav — Inbox · Search · Compose · Calendar ·
 * More. Every phone screen renders inside this. It owns the draft context (so
 * the centre Compose button and Reply both open the full-screen composer), the
 * undo toast and the notification panel; screens own their own top bar. */



export default function MobileShell({ tab, hideNav = false, composeFrom, rememberLast = false, children }) {
  const { mode, themeId } = useTheme();
  // Tablet: the nav is a left rail and is always there (screens sit beside it).
  const tablet = useMobileLayout() === MOBILE_LAYOUT.TABLET;
  const navHidden = hideNav && !tablet;
  const { org } = useMobileOrg();
  const undoToasts = useUndoStore((s) => s.toasts);
  const undoAction = useUndoStore((s) => s.undo);
  const dismissUndo = useUndoStore((s) => s.dismiss);
  const [notifOpen, setNotifOpen] = useState(false);

  return (
    <DraftProvider orgId={org?.id || null}>
      <div className={styles.shell} data-theme={mode} data-theme-variant={themeId}
        data-layout={tablet ? MOBILE_LAYOUT.TABLET : MOBILE_LAYOUT.PHONE} data-nav={navHidden ? 'hidden' : 'shown'}>
        <MobileNotifContext.Provider value={() => setNotifOpen(true)}>
          {children}
        </MobileNotifContext.Provider>
        {!navHidden && <MobileNav tab={tab} composeFrom={composeFrom} rememberLast={rememberLast} />}
        <ComposePopups />
        <UndoToast entries={undoToasts} onUndo={undoAction} onDismiss={dismissUndo} />
        <NotificationPanel open={notifOpen} onClose={() => setNotifOpen(false)} />
      </div>
    </DraftProvider>
  );
}


function MobileNav({ tab, composeFrom, rememberLast }) {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { org, orgSlug } = useMobileOrg();
  const { createDraft } = useDrafts();
  const base = orgSlug ? `/${orgSlug}` : '';
  // New mail: the inbox being viewed; the unified inbox remembers the last-used From.
  const fromFor = useNewComposeFrom(composeFrom || user?.email
    || (org?.domain ? `${user?.username || 'me'}@${org.domain}` : ''), rememberLast);

  const item = (key, icon, label, to) => (
    <button
      type="button"
      className={[styles.navItem, tab === key ? styles.navOn : ''].join(' ')}
      onClick={() => navigate(to)}
      aria-label={label}
      title={label}
      aria-current={tab === key ? 'page' : undefined}
    >
      <Icon name={icon} size={19} />
      {/* Phone: only the current tab's label shows (the widening pill); the
          tablet rail labels every item. CSS decides. */}
      <span className={styles.navLabel}>{label}</span>
    </button>
  );

  return (
    <nav className={styles.nav} aria-label="Main">
      {item(MOBILE_TAB.INBOX, 'tray.full', 'Inbox', `${base}/mail`)}
      {item(MOBILE_TAB.SEARCH, 'magnifyingglass', 'Search', `${base}/search`)}
      <button
        type="button"
        className={styles.navCompose}
        onClick={() => createDraft({ fromAddress: fromFor() })}
        aria-label="New message"
        title="New message"
      >
        <Icon name="square.and.pencil" size={20} />
        <span className={styles.navLabel}>New</span>
      </button>
      {item(MOBILE_TAB.CALENDAR, 'calendar', 'Calendar', `${base}/calendar`)}
      {item(MOBILE_TAB.MORE, 'ellipsis', 'More', `${base}/settings`)}
    </nav>
  );
}

/* A phone screen's top bar: optional leading button, title, trailing actions. */
export function MobileTopBar({ leading, title, subtitle, children }) {
  return (
    <header className={styles.topBar}>
      {leading}
      <div className={styles.topTitleWrap}>
        <h1 className={styles.topTitle} dir="auto">{title}</h1>
        {subtitle && <span className={styles.topSub}>{subtitle}</span>}
      </div>
      <div className={styles.topActions}>{children}</div>
    </header>
  );
}

export function MobileIconButton({ icon, label, onClick, badge, ...rest }) {
  return (
    <button type="button" className={styles.iconBtn} onClick={onClick} aria-label={label} title={label} {...rest}>
      <Icon name={icon} size={18} />
      {badge ? <span className={styles.iconBadge} /> : null}
    </button>
  );
}
