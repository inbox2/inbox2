import { useState, useMemo } from 'react';
import { Outlet, useLocation, useParams } from 'react-router';
import useAuth from '../../hooks/useAuth';
import useTheme from '../../hooks/useTheme';
import useAccounts from '../../hooks/useAccounts';
import useNavigationStore from '../../stores/navigationStore';
import { useMobileLayout } from '../../hooks/useIsPhone';
import { isTauri } from '../../lib/tauri';
import DraftProvider from '../../hooks/DraftProvider';
import { ComposeAction, ComposePopups } from '../ComposeWidgets/ComposeWidgets';
import NotificationPanel from '../NotificationPanel/NotificationPanel';
import ChromeBar from './ChromeBar';
import TouchStrip from '../TouchStrip/TouchStrip';
import { getLastFrom } from '../../lib/lastUsedPref';
import layoutStyles from '../../styles/layout.module.css';

/**
 * AppChrome — the single, persistent shell shared by every primary app screen.
 *
 * Every tabbed screen used to mount its own <ChromeBar> + .app wrapper, which
 * meant the chrome could (and did) drift per page — e.g. the calendar's bespoke
 * .app missed the desktop window-transparency rule and rendered a washed-out
 * chrome. Hoisting the chrome here makes it a single instance that doesn't
 * remount on navigation, and centralises the things that used to be threaded
 * through per-page props: the account list, the notifications panel, Compose
 * (on mail tabs), and the global search (now uniform — see ChromeBar).
 *
 * Pages render only their body, via <Outlet>. Shared values they still need
 * (accounts, current org, user) are exposed through the Outlet context.
 */
function deriveActiveTab(pathname) {
  if (/\/calendar(\/|$)/.test(pathname)) return 'calendar';
  // /team/:id is the Team-activity drill-in, a sub-surface of Spaces → keep it lit.
  if (/\/(spaces|team)(\/|$)/.test(pathname)) return 'spaces';
  if (/^\/lore(\/|$)/.test(pathname)) return 'lore';
  if (/\/whatsapp(\/|$)/.test(pathname)) return 'whatsapp';
  if (/\/explorer(\/|$)/.test(pathname)) return 'explorer';
  // Search is part of the mail experience (keeps the unified tab lit + Compose).
  if (/\/(mail|search)(\/|$)/.test(pathname)) return 'mail';
  // Bare /:orgSlug lands on the Command Center (Explorer).
  return 'explorer';
}

export default function AppChrome() {
  const { pathname } = useLocation();
  const { orgSlug } = useParams();
  const { organizations, user } = useAuth();
  const { mode, themeId } = useTheme();
  const mobileLayout = useMobileLayout();
  // The active channel is global nav state (the account switcher + sync engine
  // write it here), not just a URL param — read it so the chrome highlights the
  // right tab and Compose targets the right account, matching the inbox.
  const navAccountKey = useNavigationStore((s) => s.accountKey);

  const currentOrg = useMemo(
    () => organizations?.find((o) => o.slug === orgSlug || o.id === orgSlug) || organizations?.[0] || null,
    [organizations, orgSlug],
  );
  const orgId = currentOrg?.id || orgSlug || organizations?.[0]?.id || null;

  // Account list for the chrome tabs (managed mode just lists accounts). We must
  // NOT run the full sync engine (useExternalAccountSync) here: its boot effect
  // auto-selects the first account whenever none is active, which would bounce
  // the unified inbox into a channel the moment the chrome mounts. The sync
  // engine stays in the mail pages where the inbox owns it.
  const { allAccounts, reorderAccounts } = useAccounts(organizations);

  const [notifOpen, setNotifOpen] = useState(false);

  const activeTab = deriveActiveTab(pathname);
  const activeAccountKey = activeTab === 'mail' ? (navAccountKey || null) : null;
  // New mail: the filtered account → the address last sent from → the first.
  const defaultFrom =
    allAccounts.find((a) => a.key === activeAccountKey)?.email_address
    || allAccounts.find((a) => a.email_address && a.email_address === getLastFrom())?.email_address
    || allAccounts[0]?.email_address
    || '';

  const outletCtx = { currentOrg, orgId, orgSlug, organizations, user, allAccounts };

  // Phones/tablets: search, calendar and the Explorer landing swap to touch
  // screens (PhoneSwitch) that bring their own shell, so the desktop chrome
  // steps aside for them. Routes with no touch screen (spaces, team activity)
  // keep it — without it they'd lose all navigation.
  const touchScreenRoute = /\/(search|calendar)(\/|$)/.test(pathname) || (/^\/[^/]+\/?$/.test(pathname) && pathname.replace(/\/$/, '') !== '/spaces');
  if (mobileLayout && !isTauri() && touchScreenRoute) return <Outlet context={outletCtx} />;

  return (
    <DraftProvider orgId={orgId} activeAccountKey={activeAccountKey || undefined}>
      <div className={layoutStyles.app} data-theme={mode} data-theme-variant={themeId}>
        <ChromeBar
          activeTab={activeTab}
          activeAccountKey={activeAccountKey}
          accounts={allAccounts}
          onReorder={reorderAccounts}
          onNotifications={() => setNotifOpen(true)}
        >
          {/* On every tab: dropping it off the mail tab resized the tab strip (a flicker
              on every switch), and a compose popup works from anywhere. */}
          <ComposeAction defaultFrom={defaultFrom} />
        </ChromeBar>

        <Outlet context={outletCtx} />
        <TouchStrip />

        <ComposePopups />
        <NotificationPanel open={notifOpen} onClose={() => setNotifOpen(false)} />
      </div>
    </DraftProvider>
  );
}
