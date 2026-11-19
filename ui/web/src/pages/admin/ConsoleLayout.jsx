import { useState, useRef, useCallback, useEffect } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router';
import Icon from '../../components/Icon';
import { MgmtButton, MgmtSideFoot } from '../../components/management';
import useAuth from '../../hooks/useAuth';
import useDismiss from '../../hooks/useDismiss';
import useIsPhone from '../../hooks/useIsPhone';
import PasskeysModal from './PasskeysModal';
import AppSwitcher from '../../components/AppSwitcher';
import { isTauri } from '../../lib/tauri';
import { openLink } from '../../lib/openLink';
import { CONSOLE_WEB_URL } from '../../lib/webOrigin';
import api from '../../lib/api';
import { passkeysSupported } from '../../lib/passkeys';
import { consolePath } from '../../lib/consoleHost';
import { isAdminRole } from '../../lib/orgRoles';
import styles from './console.module.css';

/* Console shell — light SaaS layout: fixed left sidebar (logo, section nav,
 * user chip) around an <Outlet/> main column. Every console surface (home,
 * domains, people, rules, billing, keys, apps) renders inside this shell. */

// Paths on this host (console.inbox2.com mounts the console at the root; lib/consoleHost.js).
const NAV = [
  { to: consolePath(), end: true, icon: 'square.grid.2x2', label: 'Home' },
  { to: consolePath('domains'), icon: 'globe', label: 'Domains' },
  { to: consolePath('people'), icon: 'person.2', label: 'People' },
  { to: consolePath('rules'), icon: 'arrow.triangle.branch', label: 'Routing rules' },
  { to: consolePath('disk'), icon: 'folder', label: 'Disk', web: true },
  { to: consolePath('mail-clients'), icon: 'envelope.open', label: 'Mail clients', admin: true },
];
const NAV_ACCOUNT = [
  { to: consolePath('billing'), icon: 'creditcard', label: 'Billing & plan' },
  { to: consolePath('api-keys'), icon: 'key', label: 'API keys & devices' },
  { to: consolePath('sending'), icon: 'paperplane', label: 'Sending API', admin: true },
  { to: consolePath('applications'), icon: 'macwindow', label: 'Applications' },
  { to: consolePath('apps'), icon: 'tray.and.arrow.down', label: 'Get the apps' },
];

// Mail and Disk on their own hosts when the console has its own; same-host paths otherwise.

export default function ConsoleLayout() {
  const navigate = useNavigate();
  const { user, organizations, currentOrg } = useAuth();

  const [passkeysOpen, setPasskeysOpen] = useState(false); // the nudge's "Add a passkey"
  // Phones: the sidebar becomes a drawer behind the top bar's menu button.
  const [navOpen, setNavOpen] = useState(false);
  const sideRef = useRef(null);
  const menuBtnRef = useRef(null);
  // On phones the sidebar is an offscreen drawer that must be inert while closed.
  const isPhone = useIsPhone();
  // Closing hands focus back to the menu button, so it isn't left on a control
  // that just went offscreen (and inert).
  const closeNav = useCallback(() => {
    setNavOpen(false);
    menuBtnRef.current?.focus();
  }, []);
  useDismiss(sideRef, closeNav, navOpen);
  // Opening moves focus into the drawer.
  useEffect(() => {
    if (navOpen) sideRef.current?.querySelector('a, button')?.focus();
  }, [navOpen]);

  // "Add a passkey" nudge: shown until the user has one or X-es it out.
  // ponytail: the dismissal is per browser (localStorage), so it comes back on
  // another device — move it to a users column if that annoys.
  const nudgeKey = `inbox2.passkeyNudgeDismissed.${user?.username}`;
  const [showNudge, setShowNudge] = useState(false);
  const checkNudge = useCallback(() => {
    let dismissed = false;
    try { dismissed = !!localStorage.getItem(nudgeKey); } catch { /* storage blocked */ }
    if (dismissed || !passkeysSupported()) return;
    api.listPasskeys()
      .then((data) => setShowNudge((data.credentials || []).length === 0))
      .catch(() => { /* no nudge if we can't tell */ });
  }, [nudgeKey]);
  useEffect(() => { checkNudge(); }, [checkNudge]);
  const dismissNudge = () => {
    try { localStorage.setItem(nudgeKey, '1'); } catch { /* storage blocked */ }
    setShowNudge(false);
  };

  // Desktop: the console would replace the mail webview. Open the same path on
  // the hosted web console in the system browser and bounce back to mail, so the
  // desktop app never leaves the mail interface — regardless of how the console
  // was reached (Admin Settings, paywall upgrade, domain-settings back, …).
  useEffect(() => {
    if (!isTauri()) return;
    // The hosted console has its pages at the root: /console/domains here is /domains there.
    const page = window.location.pathname.replace(/^\/console/, '') || '/';
    openLink(`${CONSOLE_WEB_URL}${page}${window.location.search}${window.location.hash}`, { forceExternal: true });
    navigate('/', { replace: true });
  }, [navigate]);

  // Pending-DNS badge on the Domains item, derived from the auth org list (no
  // extra fetch): the org's default domain + each additional domain.
  const pendingCount = (organizations || []).reduce((n, org) => {
    const domains = org.domains?.length
      ? org.domains
      : [{ status: org.status }];
    return n + domains.filter((d) => !['receiving_mail', 'verified'].includes(d.status)).length;
  }, 0);

  const primaryOrg = organizations?.[0];

  // Desktop bounces to the system browser (effect above) — don't flash the shell.
  if (isTauri()) return null;

  const item = ({ to, end, icon, label, badge }) => (
    <NavLink
      key={to}
      to={to}
      end={end}
      className={({ isActive }) => [styles.navItem, isActive ? styles.on : ''].join(' ')}
    >
      <Icon name={icon} size={16} /> {label}
      {badge > 0 && <span className={styles.navCount}>{badge}</span>}
    </NavLink>
  );

  return (
    <div className={`${styles.shell} management`}>
      <header className={styles.mobileBar}>
        <button
          ref={menuBtnRef}
          type="button"
          className={styles.mobileMenuBtn}
          onClick={() => setNavOpen(true)}
          aria-label="Open menu"
          aria-expanded={navOpen}
        >
          <Icon name="line.3.horizontal" size={18} />
        </button>
        <img className={styles.brandMark} src="/logo-mark.png" alt="" />
        <span className={styles.brandWord}>inbox2</span>
        <span className={styles.brandKicker}>Console</span>
      </header>
      {navOpen && <div className={styles.navScrim} aria-hidden="true" />}

      {/* Following a link inside the drawer closes it. */}
      {/* eslint-disable-next-line jsx-a11y/click-events-have-key-events -- links fire click on Enter; a presentation role would drop the nav landmark */}
      <nav
        ref={sideRef}
        className={[styles.side, navOpen ? styles.sideOpen : ''].join(' ')}
        inert={isPhone && !navOpen}
        onClick={(e) => { if (navOpen && e.target.closest('a')) closeNav(); }}
      >
        <div className={styles.brand}>
          <img className={styles.brandMark} src="/logo-mark.png" alt="" />
          <span className={styles.brandWord}>inbox2</span>
          <span className={styles.brandKicker}>Console</span>
        </div>

        {NAV.filter((n) => (!n.web || !isTauri()) && (!n.admin || isAdminRole(currentOrg?.role))).map((n) => item({ ...n, badge: n.label === 'Domains' ? pendingCount : 0 }))}

        <div className={styles.navGroup}>Account</div>
        {NAV_ACCOUNT.filter((n) => !n.admin || isAdminRole(currentOrg?.role)).map(item)}

        <MgmtSideFoot
          sub={primaryOrg?.domain}
          onAction={() => setNavOpen(false)}
        />
      </nav>

      <main className={styles.main}>
        <div className={styles.mainInner}>
          <div className={styles.topBar}><AppSwitcher current="console" variant="light" /></div>
          {showNudge && (
            <div className={styles.nudge} role="status">
              <Icon name="key" size={16} />
              <span className={styles.nudgeText}>
                <strong>Make your account more secure.</strong> Add a passkey to sign in with your fingerprint, face or device PIN.
              </span>
              <MgmtButton variant="glass" size="sm" onClick={() => setPasskeysOpen(true)}>Add a passkey</MgmtButton>
              <button type="button" className={styles.nudgeClose} onClick={dismissNudge} aria-label="Dismiss">
                <Icon name="xmark" size={12} />
              </button>
            </div>
          )}
          <Outlet />
        </div>
      </main>

      {passkeysOpen && <PasskeysModal onClose={() => { setPasskeysOpen(false); checkNudge(); }} />}
    </div>
  );
}
