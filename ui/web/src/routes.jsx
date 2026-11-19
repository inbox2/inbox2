import { lazy, Suspense, useEffect } from 'react';
import { Routes, Route, Navigate, useLocation, useNavigate, useParams } from 'react-router';
import useAuth from './hooks/useAuth';
import useNavigationStore from './stores/navigationStore';
import useNewMessageNotifications from './hooks/useNewMessageNotifications';
import useMeetingReminders from './hooks/useMeetingReminders';
import useZoneAlerts from './hooks/useZoneAlerts';
import useDockBadge from './hooks/useDockBadge';
import useTrayTitle from './hooks/useTrayTitle';
import { isAuxWindowPath, TRAY_PATH } from './lib/auxWindow';
import useAccounts from './hooks/useAccounts';
import useChannelUnreadCounts from './hooks/useChannelUnreadCounts';
import NewMessagePopup from './components/NewMessagePopup/NewMessagePopup';
import ReauthPrompt from './components/ReauthPrompt/ReauthPrompt';
import ActivityPanel from './components/ActivityPanel/ActivityPanel';
import AppChrome from './components/Chrome/AppChrome';
import AppMenuBridge from './components/AppMenuBridge/AppMenuBridge';
import CommandPalette from './components/CommandPalette/CommandPalette';
import TimeZonePlanner from './components/Calendar/TimeZonePlanner';
import usePaletteStore from './stores/paletteStore';
import usePlannerStore from './stores/plannerStore';
import usePaletteShortcut from './hooks/usePaletteShortcut';
import { toggleDemoMode } from './lib/demoData';
import { isTauri } from './lib/tauri';
import { safeNextPath } from './lib/safeNext';
import { mobileLayoutNow } from './hooks/useIsPhone';
import { DISK_HOST, DISK_ORIGIN, isDiskPath, MAIL_ORIGIN, ROOT_SEGMENTS } from './lib/disk/model';
import { CONSOLE_HOST, CONSOLE_ORIGIN, consolePath, isConsolePath } from './lib/consoleHost';
import { canUseConsole } from './lib/orgRoles';
import PhoneSwitch, { MobileLayoutAttr } from './mobile/PhoneSwitch';
import RouteLoading from './components/RouteLoading';
import { runNotificationTestHarness } from './lib/demoNotifications';

/** Parse URL into navigation state — mirrors the route definitions.
 *  `page` ('mail' | 'explorer' | 'calendar' | 'settings') makes every top-level
 *  view a distinct history entry, so back/forward can land on Explorer instead of
 *  only ever rebuilding /mail URLs.
 *  `unified` distinguishes the cross-channel unified inbox (/:orgSlug/mail →
 *  UnifiedInboxView) from the org's single-channel view (/:orgSlug/mail/inbox →
 *  InboxPage). Both have accountKey=null, so without this flag the history stack
 *  can't tell them apart and back/forward breaks between them.
 *  filterFrom/filterTo carry the ?from=/?to= mail filter so a filtered drill-down
 *  (Explorer → person, "view sender") is restorable on back/forward. */
function parseUrl(pathname, search = '') {
  const sp = new URLSearchParams(search);
  const filterFrom = sp.get('from') || null;
  const filterTo = sp.get('to') || null;
  // Space filter (spc_ key) — only meaningful on the MX org inbox, but parsed
  // uniformly so back/forward restores it like the from/to filters.
  const space = sp.get('space') || null;
  // Open conversation (conv_ key) — the selected email. In the URL so a refresh
  // reopens it instead of dropping back to the list.
  const conversationId = sp.get('c') || null;
  let m;

  // /:orgSlug/mail/account/:accountKey
  m = pathname.match(/^\/([^/]+)\/mail\/account\/([^/?]+)/);
  if (m) return { page: 'mail', orgSlug: m[1], accountKey: m[2], unified: false, filterFrom, filterTo, space, conversationId };

  // /mail/account/:accountKey (no org)
  m = pathname.match(/^\/mail\/account\/([^/?]+)/);
  if (m) return { page: 'mail', orgSlug: null, accountKey: m[1], unified: false, filterFrom, filterTo, space, conversationId };

  // Search results — account-agnostic (the shared chrome navigates here from any
  // tab). Must be matched before the mail fallback, else /:orgSlug/search parses
  // as a non-unified mail view and the store bounces to the last channel.
  m = pathname.match(/^\/([^/]+)\/search/);
  if (m && m[1] !== 'mail') return { page: 'search', orgSlug: m[1], accountKey: undefined, unified: false };
  if (pathname.startsWith('/mail/search')) return { page: 'search', orgSlug: null, accountKey: undefined, unified: false };

  // /share/<name>/<token> — a Disk public link, outside any org and any login.
  if (pathname.startsWith('/share/')) return { page: 'public-link', orgSlug: null, accountKey: undefined, unified: false };

  // /disk/... (or /c/..., /d/..., the views on disk.inbox2.com) — Disk, on one org at a time and
  // not in the path (docs/plans/disk-build.md section 1); orgSlug undefined keeps the mail tabs' org.
  if (isDiskPath(pathname)) return { page: 'disk', orgSlug: undefined, accountKey: undefined, unified: false };

  // /console/... (or /, /domains, ... on console.inbox2.com) — the admin console; orgSlug
  // undefined keeps the mail tabs' org (the console's own paths name none).
  if (isConsolePath(pathname)) return { page: 'console', orgSlug: undefined, accountKey: undefined, unified: false };

  // /lore/... — Lore, the open-workload wiki (docs/plans/lore.md). Across every
  // org and channel, so it names none; orgSlug undefined keeps the mail tabs' org.
  if (pathname === '/lore' || pathname.startsWith('/lore/')) return { page: 'lore', orgSlug: undefined, accountKey: undefined, unified: false };

  // /:orgSlug/calendar and /:orgSlug/settings — non-mail, account-agnostic.
  m = pathname.match(/^\/([^/]+)\/calendar/);
  if (m) return { page: 'calendar', orgSlug: m[1], accountKey: undefined, unified: false };
  m = pathname.match(/^\/([^/]+)\/settings/);
  if (m) return { page: 'settings', orgSlug: m[1], accountKey: undefined, unified: false };
  m = pathname.match(/^\/([^/]+)\/spaces/);
  if (m) return { page: 'spaces', orgSlug: m[1], accountKey: undefined, unified: false };

  // /:orgSlug/mail (unified) vs /:orgSlug/mail/<anything> (channel/inbox view)
  m = pathname.match(/^\/([^/]+)\/mail(\/[^?]*)?/);
  if (m) {
    const rest = (m[2] || '').replace(/\/$/, '');
    return { page: 'mail', orgSlug: m[1], accountKey: null, unified: rest === '', filterFrom, filterTo, space, conversationId };
  }

  // /mail (unified) vs /mail/<anything>
  if (pathname.startsWith('/mail')) {
    const rest = pathname.slice('/mail'.length).replace(/\/$/, '');
    return { page: 'mail', orgSlug: null, accountKey: null, unified: rest === '', filterFrom, filterTo, space, conversationId };
  }

  // Org-less non-mail routes (local standalone mode has no org slug).
  if (pathname === '/settings') return { page: 'settings', orgSlug: null, accountKey: undefined, unified: false };
  if (pathname === '/calendar') return { page: 'calendar', orgSlug: null, accountKey: undefined, unified: false };
  if (pathname === '/spaces') return { page: 'spaces', orgSlug: null, accountKey: undefined, unified: false };

  // /explorer (org-less) and /:orgSlug (the Explorer landing page).
  if (pathname === '/explorer') return { page: 'explorer', orgSlug: null, accountKey: undefined, unified: false };
  m = pathname.match(/^\/([^/]+)\/?$/);
  if (m) return { page: 'explorer', orgSlug: m[1], accountKey: undefined, unified: false };

  // Fallback — keep current account, treat as mail.
  m = pathname.match(/^\/([^/]+)/);
  return { page: 'mail', orgSlug: m?.[1] || null, accountKey: undefined, unified: false };
}
// The primary mail surfaces stay in the entry chunk — they're the first thing
// painted after boot and lazy-loading them would add a round trip to first mail.
import InboxPage from './pages/inbox/InboxPage';
import UnifiedInboxView from './pages/inbox/UnifiedInboxView';
// Rendered directly by ProtectedRoute (not via a <Route>), so it must be eager.
import OfflinePage from './pages/system/OfflinePage';
import { isSetupComplete, isStandaloneDesktop } from './lib/setupMode';
import { ACTIVE_ACCOUNT_KEY, ACTIVE_CONVERSATION_KEY } from './lib/storageKeys';

// Everything else is route-split: without this the entry chunk carried every
// page — FullCalendar, the Explorer force-graph, all console screens — as one
// 3 MB parse before first render.
const LoginPage = lazy(() => import('./pages/auth/LoginPage'));
const SignupPage = lazy(() => import('./pages/auth/SignupPage'));
const WaitlistPage = lazy(() => import('./pages/auth/WaitlistPage'));
const ForgotPasswordPage = lazy(() => import('./pages/auth/ForgotPasswordPage'));
const ResetPasswordPage = lazy(() => import('./pages/auth/ResetPasswordPage'));
const AcceptInvitePage = lazy(() => import('./pages/auth/AcceptInvitePage'));
const ConfirmEmailPage = lazy(() => import('./pages/auth/ConfirmEmailPage'));
const SsoCallbackPage = lazy(() => import('./pages/auth/SsoCallbackPage'));
const SamlCallbackPage = lazy(() => import('./pages/auth/SamlCallbackPage'));
const LinkDevicePage = lazy(() => import('./pages/auth/LinkDevicePage'));
const MeetPage = lazy(() => import('./pages/meet/MeetPage'));
const AppOauthConsentPage = lazy(() => import('./pages/auth/AppOauthConsentPage'));
const CommandCenterPage = lazy(() => import('./pages/command/CommandCenterPage'));
const OnboardingPage = lazy(() => import('./pages/onboarding/OnboardingPage'));
const SetupWizardPage = lazy(() => import('./pages/setup/SetupWizardPage'));
const SettingsPage = lazy(() => import('./pages/settings/SettingsPage'));
const TriageLabPage = lazy(() => import('./pages/lab/TriageLabPage'));
const SearchResultsView = lazy(() => import('./pages/search/SearchResultsView'));
const CalendarPage = lazy(() => import('./pages/calendar/CalendarPage'));
const WhatsAppPage = lazy(() => import('./pages/whatsapp/WhatsAppPage'));
const DiskLayout = lazy(() => import('./pages/disk/DiskLayout'));
const DiskBrowser = lazy(() => import('./pages/disk/DiskBrowser'));
const PublicLinkPage = lazy(() => import('./pages/disk/PublicLinkPage'));
const NotificationPage = lazy(() => import('./pages/notification/NotificationPage'));
const TrayPage = lazy(() => import('./pages/tray/TrayPage'));
const ConsoleLayout = lazy(() => import('./pages/admin/ConsoleLayout'));
const ConsoleHome = lazy(() => import('./pages/admin/ConsoleHome'));
const ConsoleDomains = lazy(() => import('./pages/admin/ConsoleDomains'));
const ConsolePeople = lazy(() => import('./pages/admin/ConsolePeople'));
const ConsoleRules = lazy(() => import('./pages/admin/ConsoleRules'));
const ConsoleDisk = lazy(() => import('./pages/admin/ConsoleDisk'));
const ConsoleBilling = lazy(() => import('./pages/admin/ConsoleBilling'));
const ConsoleApps = lazy(() => import('./pages/admin/ConsoleApps'));
const ConsoleApplications = lazy(() => import('./pages/admin/ConsoleApplications'));
const ConsoleSending = lazy(() => import('./pages/admin/ConsoleSending'));
const ConsoleMailClients = lazy(() => import('./pages/admin/ConsoleMailClients'));
const DomainSettingsPage = lazy(() => import('./pages/admin/DomainSettingsPage'));
const MemberAccessPage = lazy(() => import('./pages/admin/MemberAccessPage'));
const ApiKeysPage = lazy(() => import('./pages/admin/ApiKeysPage'));
const SpaceDashboard = lazy(() => import('./pages/dashboard/SpaceDashboard'));
const LoreApp = lazy(() => import('./pages/lore/LoreApp'));
const MemberActivityPage = lazy(() => import('./pages/dashboard/MemberActivityPage'));
const NotFoundPage = lazy(() => import('./pages/system/NotFoundPage'));
// The phone shell (src/mobile/) — its own chunk; desktop never loads it.
const MobileMail = lazy(() => import('./mobile/MobileMail'));
const MobileSearch = lazy(() => import('./mobile/MobileSearch'));
const MobileCalendar = lazy(() => import('./mobile/MobileCalendar'));
const MobileMore = lazy(() => import('./mobile/MobileMore'));
const NoAccessPage = lazy(() => import('./pages/system/NoAccessPage'));
const ErrorPage = lazy(() => import('./pages/system/ErrorPage'));
const UpgradeRequiredPage = lazy(() => import('./pages/system/UpgradeRequiredPage'));

function ProtectedRoute({ children }) {
  const { user, loading, offline, retryConnection } = useAuth();
  if (loading) return <RouteLoading />;
  // Tauri first-run: force setup wizard before requiring login
  if (isTauri() && !isSetupComplete()) {
    return <Navigate to="/setup" replace />;
  }
  // Tauri standalone mode: no API auth needed, data is local. MX mode falls
  // through to the login check below — it has a web session and must use it.
  if (isStandaloneDesktop()) {
    return children;
  }
  // No user because the API is unreachable ≠ signed out. Say which one it is;
  // the login screen can't help when the server is the thing that's down.
  if (!user && offline) return <OfflinePage onRetry={retryConnection} />;
  if (!user) return <Navigate to="/login" replace />;
  return children;
}

function GuestRoute({ children }) {
  const { user, organizations, loading } = useAuth();
  const location = useLocation();
  if (loading) return null;
  // Tauri first-run: force setup wizard before login
  if (isTauri() && !isSetupComplete()) {
    return <Navigate to="/setup" replace />;
  }
  if (user) {
    // Honor a local-only ?next= return path first — e.g. the device-link /link
    // approval page bounces here via /login?next=/link…; an already-signed-in user
    // must land back on /link to finish linking, not get dumped on the console.
    const next = safeNextPath(location.search);
    // The management console is the post-login home (login → admin → enter domain),
    // regardless of whether a domain is connected yet — but it's web-only. On desktop
    // route through the root redirect, which resolves to the mail client; phones go
    // to their mail too, like the apps (the console is a tap away under More).
    // Members never get the console: their home is their mail.
    const toConsole = !isTauri() && !mobileLayoutNow() && canUseConsole(organizations);
    return <Navigate to={next || (toConsole ? consolePath() : '/')} replace />;
  }
  return children;
}

// /:orgSlug on a phone (the desktop Explorer landing) → that workspace's mail.
function PhoneToMail() {
  const { orgSlug } = useParams();
  return <Navigate to={`/${orgSlug}/mail`} replace />;
}

// /disk/...: Disk on this host, unless it has its own (disk.inbox2.com). There a /disk/... URL
// (an old link, an in-app notification's path) drops the prefix; on the mail host a Pages build
// with VITE_DISK_ORIGIN sends it over. The session cookie is the API's, so it holds on both hosts.
function DiskMount() {
  const { pathname, search, hash } = useLocation();
  const rest = `${pathname.slice('/disk'.length) || '/'}${search}${hash}`;
  const away = !DISK_HOST && DISK_ORIGIN && !isTauri();
  useEffect(() => { if (away) window.location.replace(`${DISK_ORIGIN}${rest}`); }, [away, rest]);
  if (DISK_HOST) return <Navigate to={rest} replace />;
  if (away) return null;
  return diskShell();
}

// /console/...: the console on this host, unless it has its own (console.inbox2.com). There a
// /console/... URL (an in-app link, an old bookmark) drops the prefix; elsewhere a Pages build with
// VITE_CONSOLE_ORIGIN sends it over. The desktop app keeps it inside, under /console.
function ConsoleMount() {
  const { pathname, search, hash } = useLocation();
  const rest = `${pathname.slice('/console'.length) || '/'}${search}${hash}`;
  const away = !CONSOLE_HOST && CONSOLE_ORIGIN && !isTauri();
  useEffect(() => { if (away) window.location.replace(`${CONSOLE_ORIGIN}${rest}`); }, [away, rest]);
  if (CONSOLE_HOST) return <Navigate to={rest} replace />;
  if (away) return null;
  return <ProtectedRoute><ConsoleGate /></ProtectedRoute>;
}

// Owners and admins only; a member who opens a console URL lands on their mail.
function ConsoleGate() {
  const { organizations } = useAuth();
  const toMail = !canUseConsole(organizations);
  const offHost = toMail && CONSOLE_HOST && !!MAIL_ORIGIN;
  useEffect(() => { if (offHost) window.location.replace(MAIL_ORIGIN); }, [offHost]);
  if (offHost) return null;
  if (toMail) return <Navigate to="/" replace />;
  return <ConsoleLayout />;
}

// The console's pages, relative: under /console here, at the root of console.inbox2.com.
const consolePages = () => (
  <>
    <Route index element={<ConsoleHome />} />
    <Route path="domains" element={<ConsoleDomains />} />
    {/* Per-domain settings (Settings / DNS / Deliverability / Encryption / Advanced / Migration). */}
    <Route path="domains/:slug" element={<DomainSettingsPage />} />
    <Route path="people" element={<ConsolePeople />} />
    {/* Per-member access page (domains, personal-mailbox exclusion, extending rules). */}
    <Route path="team/:orgId/:memberId" element={<MemberAccessPage />} />
    <Route path="rules" element={<ConsoleRules />} />
    <Route path="disk" element={isTauri() ? <Navigate to={consolePath()} replace /> : <ConsoleDisk />} />
    <Route path="billing" element={<ConsoleBilling />} />
    {/* Personal API keys management. */}
    <Route path="api-keys" element={<ApiKeysPage />} />
    <Route path="apps" element={<ConsoleApps />} />
    {/* Registered third-party applications (brokered provider OAuth). */}
    <Route path="applications" element={<ConsoleApplications />} />
    {/* Sending API (docs/ESP.md) and mail clients (docs/Mail-Clients.md). */}
    <Route path="sending" element={<ConsoleSending />} />
    <Route path="mail-clients" element={<ConsoleMailClients />} />
  </>
);

const diskShell = () => (isTauri() ? <Navigate to="/" replace /> : <ProtectedRoute><DiskLayout /></ProtectedRoute>);

function OrgRedirect() {
  const { currentOrgSlug, loading } = useAuth();
  if (loading) return null;

  // First-run setup wizard for desktop with empty DB
  if (isTauri() && !isSetupComplete()) {
    return <Navigate to="/setup" replace />;
  }

  // Restore the last-focused channel across restarts. The selection is persisted
  // on every account switch (navigationStore); without this the app always boots
  // to the unified inbox. Falls through to unified when no channel was selected
  // (or the user last viewed unified, which clears the key).
  const base = currentOrgSlug ? `/${currentOrgSlug}` : '';
  const savedAccount = localStorage.getItem(ACTIVE_ACCOUNT_KEY);
  // Reopen the conversation that was open before the refresh — persisted like the
  // account, since the desktop reloads to '/' and loses the URL's ?c=.
  const savedConv = localStorage.getItem(ACTIVE_CONVERSATION_KEY);
  // Not on a phone: there the list comes first, and a reopened thread would
  // cover it on every visit.
  const convQuery = savedConv && !mobileLayoutNow() ? `?c=${savedConv}` : '';
  if (savedAccount) return <Navigate to={`${base}/mail/account/${savedAccount}${convQuery}`} replace />;

  if (currentOrgSlug) return <Navigate to={`/${currentOrgSlug}/mail${convQuery}`} replace />;
  // Desktop is a standalone mail client — the MX management console is a web-only
  // concept and must never be the desktop landing. Fall back to the unified inbox.
  if (isTauri()) return <Navigate to="/mail" replace />;
  // Signed in but no domain connected yet → the management console.
  return <Navigate to={consolePath()} replace />;
}

/** Bridges react-router ↔ NavigationManager: binds navigate(), syncs URL→state. */
function NavigationSync() {
  const navigate = useNavigate();
  const location = useLocation();
  const bindNavigate = useNavigationStore(s => s.bindNavigate);
  const syncFromUrl = useNavigationStore(s => s.syncFromUrl);

  useEffect(() => { bindNavigate(navigate); }, [navigate, bindNavigate]);

  // Depend on search too, not just pathname: navigateTo bumps an internal
  // skip-counter whenever it drives a URL change (including search-only ones like
  // applying/clearing a ?to=/?from= filter). If this effect only fired on pathname
  // changes, a search-only navigation would leak that counter, and the *next* real
  // navigation (e.g. switching tabs) would be silently swallowed — leaving the store
  // desynced from the URL and the history stack stuck.
  useEffect(() => {
    syncFromUrl(parseUrl(location.pathname, location.search));
  }, [location.pathname, location.search, syncFromUrl]);

  return null;
}

/** The command palette, mounted once for the whole app.
 *  It used to live on five pages, each with its own copy and its own ⌘P
 *  listener — which is why it was missing everywhere else (Settings, the
 *  console, Triage Lab, the spaces board). Pages now only register what they
 *  can *do* (compose, toggle unread, …) via usePaletteActions.
 *  ⇧⌘D rides along here: demo data on/off, the one shortcut that has to work
 *  from any screen you might want to screenshot. */
function GlobalCommandPalette() {
  const { pathname } = useLocation();
  const { user } = useAuth();
  const open = usePaletteStore(s => s.open);
  const actions = usePaletteStore(s => s.actions);
  const toggle = usePaletteStore(s => s.toggle);
  const close = usePaletteStore(s => s.close);

  usePaletteShortcut(toggle);
  useEffect(() => {
    const handler = (e) => {
      if (!(e.metaKey || e.ctrlKey) || !e.shiftKey || e.altKey) return;
      if (e.key?.toLowerCase() !== 'd' && e.code !== 'KeyD') return;
      e.preventDefault();
      toggleDemoMode();
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);

  // The notification popup is its own little Tauri window, and the signed-out
  // screens (login, waitlist, a consent page) have nothing to command.
  if (isAuxWindowPath(pathname)) return null;
  if (!user && !isStandaloneDesktop()) return null;
  return <CommandPalette open={open} onClose={close} actions={actions} />;
}

/** The timezone planner, mounted once so the calendar's zone picker and the
 *  command palette can both open it. */
function GlobalTimeZonePlanner() {
  const open = usePlannerStore(s => s.open);
  const close = usePlannerStore(s => s.closePlanner);
  return open ? <TimeZonePlanner open onClose={close} /> : null;
}

/** Global new-message notification listener + popup.
 *  Skipped on the /notification route (Tauri popup window) to avoid
 *  a second listener on the shared syncManager singleton. */
function NewMessageNotifier() {
  const { pathname } = useLocation();
  if (isAuxWindowPath(pathname)) return null;
  return <NewMessageNotifierInner />;
}

/** Global one-time "sign-in expired — reconnect" alert for external accounts
 *  whose OAuth tokens died. Skipped in the notification popup window. */
function ReauthNotifier() {
  const { pathname } = useLocation();
  if (isAuxWindowPath(pathname)) return null;
  return <ReauthPrompt />;
}

/** Triage progress float. Skipped in the notification popup window, where it
 *  landed on top of the alert's action buttons. */
function ActivityNotifier() {
  const { pathname } = useLocation();
  if (isAuxWindowPath(pathname)) return null;
  return <ActivityPanel />;
}

function NewMessageNotifierInner() {
  useNewMessageNotifications();
  useMeetingReminders();
  useZoneAlerts();
  useDockBadge();
  useTrayTitle();
  // Keep the unread recounts running on chrome-less routes too (Settings,
  // console, triage-lab): the hook's only other mount is ChromeBar, so with
  // Settings open new mail never reached unreadStore and the dock badge froze.
  const { organizations } = useAuth();
  const { allAccounts } = useAccounts(organizations);
  useChannelUnreadCounts(allAccounts);
  // Dev-only: fire sample alerts shortly after launch to exercise the desktop
  // notification window's stacking. No-op in production builds.
  useEffect(() => { runNotificationTestHarness(); }, []);
  return <NewMessagePopup />;
}

// disk.inbox2.com serves Disk, sign-in and public links; console.inbox2.com the console, sign-in
// and onboarding (connecting a domain). Everything else is mail's and goes to mail.inbox2.com
// (the mail host already sends /disk/... and /console/... the other way). Only in a build with
// VITE_MAIL_ORIGIN, so dev keeps one host.
const HOST_KEEPS = /^\/(login|signup|waitlist|forgot-password|reset-password|accept-invite|confirm-email|sso\/callback|sso\/saml\/callback|link|share|no-access|error)(\/|$)/;
const CONSOLE_HOST_KEEPS = /^\/(onboarding)(\/|$)/;
const ownHostServes = (pathname) =>
  (DISK_HOST && isDiskPath(pathname)) || (CONSOLE_HOST && (isConsolePath(pathname) || CONSOLE_HOST_KEEPS.test(pathname)));

export default function AppRoutes() {
  const { pathname, search, hash } = useLocation();
  const toMail = (DISK_HOST || CONSOLE_HOST) && !!MAIL_ORIGIN && !ownHostServes(pathname) && !HOST_KEEPS.test(pathname);
  useEffect(() => { if (toMail) window.location.replace(`${MAIL_ORIGIN}${pathname}${search}${hash}`); }, [toMail, pathname, search, hash]);
  if (toMail) return null;
  return (
    <>
    <NavigationSync />
    <MobileLayoutAttr />
    {/* Mail's global surfaces: not on the disk host. */}
    {!DISK_HOST && !CONSOLE_HOST && <>
    <GlobalCommandPalette />
    <GlobalTimeZonePlanner />
    <NewMessageNotifier />
    {/* Background work (triage) follows you across tabs — bottom-right float. */}
    <ActivityNotifier />
    <ReauthNotifier />
    <AppMenuBridge />
    </>}
    {/* Lazy route chunks: a spinner on the page's canvas while one loads, not the bare window. */}
    <Suspense fallback={<RouteLoading />}>
    <Routes>
      <Route path="/login" element={<GuestRoute><LoginPage /></GuestRoute>} />
      <Route path="/signup" element={<GuestRoute><SignupPage /></GuestRoute>} />
      <Route path="/waitlist" element={<GuestRoute><WaitlistPage /></GuestRoute>} />
      <Route path="/forgot-password" element={<GuestRoute><ForgotPasswordPage /></GuestRoute>} />
      <Route path="/reset-password" element={<GuestRoute><ResetPasswordPage /></GuestRoute>} />
      <Route path="/accept-invite" element={<AcceptInvitePage />} />
      <Route path="/confirm-email" element={<ConfirmEmailPage />} />
      <Route path="/sso/callback" element={<SsoCallbackPage />} />
      <Route path="/sso/saml/callback" element={<SamlCallbackPage />} />
      {/* Device-link approval page — opened in the system browser by a desktop/
          mobile client. Not guest/protected-wrapped: it gates on auth itself and
          sends signed-out users through /login?next=. See docs/Device-Link.md. */}
      <Route path="/link" element={<LinkDevicePage />} />
      {/* Public meet-link scheduler (docs/Calendar.md) — the token is the capability. */}
      <Route path="/meet/:token" element={<MeetPage />} />
      {/* Consent screen for a registered application's brokered provider OAuth
          (docs/App-OAuth.md). Deliberately outside every auth wrapper: the person
          connecting their Google/Microsoft mailbox needn't have an inbox2 account. */}
      <Route path="/oauth/consent" element={<AppOauthConsentPage />} />
      {/* Disk public link viewer (docs/plans/disk-spec.md F4): no login, no org. */}
      <Route path="/share/:a" element={<PublicLinkPage />} />
      <Route path="/share/:a/:b" element={<PublicLinkPage />} />
      {!DISK_HOST && !CONSOLE_HOST && <Route path="/" element={<ProtectedRoute><OrgRedirect /></ProtectedRoute>} />}
      {/* console.inbox2.com: the console at the root. Static segments outrank /:orgSlug. */}
      {CONSOLE_HOST && <Route element={<ProtectedRoute><ConsoleGate /></ProtectedRoute>}>{consolePages()}</Route>}
      {/* disk.inbox2.com: Disk at the root. Static segments outrank /:orgSlug. */}
      {DISK_HOST && (
        <Route element={diskShell()}>
          <Route path="/" element={<DiskBrowser />} />
          {ROOT_SEGMENTS.map((seg) => <Route key={seg} path={`/${seg}/*`} element={<DiskBrowser />} />)}
        </Route>
      )}
      <Route path="/mail" element={<ProtectedRoute><PhoneSwitch phone={<MobileMail />}><UnifiedInboxView /></PhoneSwitch></ProtectedRoute>} />
      <Route path="/mail/account/:accountKey" element={<ProtectedRoute><PhoneSwitch phone={<MobileMail />}><InboxPage /></PhoneSwitch></ProtectedRoute>} />
      <Route path="/setup" element={<SetupWizardPage />} />
      <Route path="/onboarding" element={<ProtectedRoute><OnboardingPage /></ProtectedRoute>} />
      <Route path="/settings" element={<ProtectedRoute><PhoneSwitch phone={<MobileMore />}><SettingsPage /></PhoneSwitch></ProtectedRoute>} />
      {/* Triage Lab — desktop-only AI scoring harness (fixtures + prompt tuning). */}
      <Route path="/triage-lab" element={<ProtectedRoute><TriageLabPage /></ProtectedRoute>} />
      {/* MX admin console (light) + per-domain Command Center (dark). Login-gated:
          it's also the first-run landing for a signed-in user with no org yet
          (connect a domain → become its owner), so it can't be blanket admin-only.
          Per-org admin actions are enforced server-side + hidden in the UI. */}
      <Route path="/console" element={<ConsoleMount />}>{consolePages()}</Route>
      {/* Shared-chrome screens, org-less (design-preview / no-login, like /console).
          The single ChromeBar lives in AppChrome; pages render via <Outlet>. */}
      <Route element={<AppChrome />}>
        {/* /spaces is a real product surface (renders org data) → require auth. */}
        <Route path="/spaces" element={<ProtectedRoute><SpaceDashboard /></ProtectedRoute>} />
      </Route>
      <Route path="/notification" element={<NotificationPage />} />
      <Route path={TRAY_PATH} element={<TrayPage />} />
      <Route path="/no-access" element={<NoAccessPage />} />
      <Route path="/error" element={<ErrorPage />} />
      <Route path="/upgrade" element={<UpgradeRequiredPage />} />
      {/* Org-scoped routes — URL addressable */}
      <Route path="/:orgSlug/mail" element={<ProtectedRoute><PhoneSwitch phone={<MobileMail />}><UnifiedInboxView /></PhoneSwitch></ProtectedRoute>} />
      <Route path="/:orgSlug/mail/inbox" element={<ProtectedRoute><PhoneSwitch phone={<MobileMail />}><InboxPage /></PhoneSwitch></ProtectedRoute>} />
      <Route path="/:orgSlug/mail/account/:accountKey" element={<ProtectedRoute><PhoneSwitch phone={<MobileMail />}><InboxPage /></PhoneSwitch></ProtectedRoute>} />
      {/* Shared-chrome screens (protected) — one ChromeBar via AppChrome (layout
          route); each page renders only its body through <Outlet>. Covers the
          org-less (/explorer, /mail/search) and org-scoped patterns alike. */}
      <Route element={<ProtectedRoute><AppChrome /></ProtectedRoute>}>
        {/* Explorer is a desktop graph; a phone lands in its mail instead. */}
        <Route path="/explorer" element={<PhoneSwitch phone={<Navigate to="/mail" replace />}><CommandCenterPage /></PhoneSwitch>} />
        <Route path="/mail/search" element={<PhoneSwitch phone={<MobileSearch />}><SearchResultsView /></PhoneSwitch>} />
        {/* Lore — full window (docs/plans/lore.md); its Today panel lives in the unified inbox. */}
        <Route path="/lore/*" element={<PhoneSwitch phone={<Navigate to="/mail" replace />}><LoreApp /></PhoneSwitch>} />
        <Route path="/:orgSlug" element={<PhoneSwitch phone={<PhoneToMail />}><CommandCenterPage /></PhoneSwitch>} />
        <Route path="/:orgSlug/search" element={<PhoneSwitch phone={<MobileSearch />}><SearchResultsView /></PhoneSwitch>} />
        {/* Local WhatsApp (desktop): WhatsApp Desktop's database on this Mac, read-only (lib/localWhatsApp.js). */}
        {isTauri() && <Route path="/whatsapp" element={<WhatsAppPage />} />}
        {isTauri() && <Route path="/:orgSlug/whatsapp" element={<WhatsAppPage />} />}
        <Route path="/:orgSlug/spaces" element={<SpaceDashboard />} />
        <Route path="/:orgSlug/team/:memberId" element={<MemberActivityPage />} />
        <Route path="/:orgSlug/calendar" element={<PhoneSwitch phone={<MobileCalendar />}><CalendarPage /></PhoneSwitch>} />
        <Route path="/:orgSlug/calendar/:eventId" element={<PhoneSwitch phone={<MobileCalendar />}><CalendarPage /></PhoneSwitch>} />
      </Route>
      {/* Disk — its own management-skin shell (sidebar of drives and views). Web only for now: desktop goes home. */}
      {/* Not on console.inbox2.com, where /disk is the console's Disk admin page. */}
      {!CONSOLE_HOST && (
        <Route path="/disk" element={<DiskMount />}>
          {/* One route: lib/disk/model.js parses /disk/c/..., /disk/d/..., the views and ids.
              The index route is bare /disk, which "*" does not match; DiskBrowser redirects it to C:\. */}
          <Route index element={<DiskBrowser />} />
          <Route path="*" element={<DiskBrowser />} />
        </Route>
      )}
      <Route path="/:orgSlug/settings" element={<ProtectedRoute><PhoneSwitch phone={<MobileMore />}><SettingsPage /></PhoneSwitch></ProtectedRoute>} />
      <Route path="*" element={<NotFoundPage />} />
    </Routes>
    </Suspense>
    </>
  );
}
