import { createContext, useState, useCallback, useMemo, useRef, useEffect } from 'react';
import api, { CLOUD_AUTH_TOKEN, SESSION_EXPIRED_EVENT, TOKEN_ADOPTED_EVENT } from '../lib/api';
import { AUTH_SIGNED_IN, AUTH_SIGNED_OUT, announceAuth, onAuthBroadcast, reactionTo } from '../lib/authBroadcast';
import { getSecret } from '../lib/secretStore';
import { pauseCable, resumeCable } from '../lib/cable';
import { onUnsavedChange, unsavedWork } from '../lib/unsavedWork';
import SignedOutScreen from '../components/SignedOutScreen';
import { passkeysSupported, signInWithPasskey } from '../lib/passkeys';
import pushSync from '../lib/pushSync';
import orgLiveMail from '../lib/orgLiveMail';
import mxMirror from '../lib/mxMirror';
import { isAdminRole, isOwnerRole } from '../lib/orgRoles';
import { isTauri } from '../lib/tauri';
import { CACHED_ACCOUNT } from '../lib/storageKeys';
import log from '../lib/log';
import { isAuxWindowPath } from '../lib/auxWindow';

// eslint-disable-next-line react-refresh/only-export-components
export const AuthContext = createContext(null);

// Backoff for the session-restore retry while the API is unreachable. A flat
// 10s poll produced 5,706 failed /account calls during the Aug 2026 outage;
// doubling to a 2-minute ceiling still recovers promptly without hammering.
// The desktop new-mail popup (/notification) is a second, mostly hidden webview
// running this same provider. WebKit suspends a hidden webview, so any socket it
// opens stalls silently — keep realtime (PushSync + org streams) to the main window.
const IS_NOTIFICATION_POPUP = typeof window !== 'undefined' && isAuxWindowPath(window.location.pathname);

// Pages that never act on another tab's sign-in or sign-out: the public link
// viewer has no session of its own, and the desktop's notification popup is not a working tab.
const IGNORES_AUTH_SIGNAL = () => IS_NOTIFICATION_POPUP || /^\/share\//.test(window.location.pathname);

const RESTORE_RETRY_MS = 10_000;
const RESTORE_RETRY_MAX_MS = 120_000;

// Stale-while-revalidate for GET /account: the last successful payload is
// cached so the shell paints immediately on the next boot instead of holding
// every route at `null` for a network round trip. restore() still runs and
// corrects the state (a 401 clears it and bounces to login).
function readCachedAccount() {
  try {
    const data = JSON.parse(localStorage.getItem(CACHED_ACCOUNT));
    return data?.account ? data : null;
  } catch { return null; }
}
function writeCachedAccount(data) {
  const account = data?.account || data?.user;
  if (!account) return;
  try {
    localStorage.setItem(CACHED_ACCOUNT, JSON.stringify({
      account,
      organizations: data.organizations || [],
      current_org_slug: data.current_org_slug || null,
    }));
  } catch { /* storage unavailable — cache is best-effort */ }
}
function clearCachedAccount() {
  try { localStorage.removeItem(CACHED_ACCOUNT); } catch { /* ignore */ }
}

// `users.default_timezone` defaults to "UTC", so "UTC" means "never chosen":
// adopt this device's zone instead. Meet links and the scheduling assistant
// evaluate working hours in it — left at UTC, a 09:00–17:00 day in Amsterdam
// was offered as 11:00–19:00. Fire-and-forget; the settings page can change it.
// ponytail: someone who really wants UTC on a non-UTC machine gets overwritten
// once per sign-in; add an explicit "chosen" flag on the user if that happens.
function adoptDeviceTimezone(user) {
  const device = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (!user || !device || device === 'UTC' || (user.default_timezone && user.default_timezone !== 'UTC')) return;
  // Promise.resolve().then: nothing here may throw into the caller's restore.
  Promise.resolve()
    .then(() => api.patch('/account', { default_timezone: device }))
    .then(() => log.info('Auth', `default_timezone was unset; adopted ${device}`))
    .catch((e) => log.warn('Auth', `adopting ${device} failed: ${e?.message || e}`));
}

export default function AuthProvider({ children }) {
  const [authState, setAuthState] = useState(() => {
    const cached = readCachedAccount();
    if (cached) {
      return {
        user: cached.account,
        organizations: cached.organizations || [],
        currentOrgSlug: cached.current_org_slug,
        offline: false,
        loading: false,
      };
    }
    return {
      user: null,
      organizations: [],
      currentOrgSlug: null,
      // The API is unreachable — distinct from "signed out". Both have user:null,
      // but only one of them means the session is gone.
      offline: false,
      loading: true, // until the token hydrates from the secret store
    };
  });
  const [signedOut, setSignedOut] = useState(null); // null | 'elsewhere' | 'expired' | 'revoked' (the signed-out screen)
  // The latest of both, for the callbacks below (the broadcast handler, logout).
  const authStateRef = useRef({ user: null });
  const signedOutRef = useRef(null);
  const loggingOutRef = useRef(false);
  useEffect(() => { authStateRef.current = authState; signedOutRef.current = signedOut; }, [authState, signedOut]);
  const initialized = useRef(false);
  // Lets the offline screen's Retry button re-run the restore that the effect owns.
  const restoreRef = useRef(null);

  useEffect(() => {
    if (initialized.current) return;
    initialized.current = true;

    let retryTimer = null;
    let retryDelay = RESTORE_RETRY_MS;

    const restore = async () => {
      clearTimeout(retryTimer); // a manual Retry pre-empts the pending one
      await api.ready; // desktop: bearer hydrates from the encrypted store
      // Restore from whatever bearer is stored — an MX session token OR a
      // device-link ink_ key. GET /account returns the user's orgs for an ink_
      // key too, so linking a device surfaces the MX inbox + domains, matching
      // iOS/Android (adoptLinkedToken). Desktop only attempts when a token is
      // present; web has no stored bearer (its session is the HttpOnly cookie),
      // so it always attempts — getAccount() authenticates via the cookie (or 401s).
      const canRestore = isTauri() ? !!api.token : true;
      if (!canRestore) {
        // Say so. This is a *silent* signed-out state on desktop — the local
        // channels keep syncing, so the app looks healthy while everything
        // cloud-backed is off: no PushSyncChannel (the effect below is gated on
        // authState.user), so no realtime cloud push, and no renewal of the
        // provider push subscriptions, which then lapse days later and take the
        // mobile push lane down with them. Logging nothing here made that chain
        // invisible; the only symptom was "desktop is a minute behind".
        log.warn('Auth', 'No stored bearer — cloud signed out (no realtime push; provider push subs will not renew)')
        clearCachedAccount();
        setAuthState({ user: null, organizations: [], currentOrgSlug: null, offline: false, loading: false });
        return;
      }
      log.info('Auth', 'Restoring session')
      try {
        const data = await api.getAccount();
        const user = data.account || data.user
        log.info('Auth', `Session restored user=${user?.username || 'unknown'} orgs=${(data.organizations || []).length}`)
        retryDelay = RESTORE_RETRY_MS;
        writeCachedAccount(data);
        adoptDeviceTimezone(user);
        setAuthState({
          user,
          organizations: data.organizations || [],
          currentOrgSlug: data.current_org_slug,
          offline: false,
          loading: false,
        })
      } catch (e) {
        // Only an actual auth rejection means the stored token is dead. A
        // network error / 5xx / mid-deploy blip at boot must NOT wipe the
        // encrypted store — that permanently signed the desktop out of MX
        // (externals kept working, so it looked like "the MX channels are
        // gone") even though the server-side key was still valid.
        if (e?.status === 401 || e?.status === 403) {
          log.warn('Auth', 'Stored token invalid, clearing session')
          api.setToken(null);
          clearCachedAccount();
          setAuthState({ user: null, organizations: [], currentOrgSlug: null, offline: false, loading: false });
          return;
        }
        // Unreachable, not signed out. Say so and keep retrying, instead of
        // rendering the login screen — during the Aug 7–12 2026 API outage the
        // desktop still held a valid session for five days but showed a login
        // form that couldn't reach the server either.
        log.warn('Auth', `Session restore failed transiently (${e?.status || e?.message}) — keeping stored token, retrying in ${retryDelay / 1000}s`)
        // Already painted from the cached account? Keep it — a transient API
        // blip must not swap a working (cached/local-channel) app for the
        // offline screen. Without a cached user the offline screen is right.
        setAuthState((s) => s.user
          ? { ...s, offline: false, loading: false }
          : { user: null, organizations: [], currentOrgSlug: null, offline: true, loading: false });
        retryTimer = setTimeout(restore, retryDelay);
        retryDelay = Math.min(retryDelay * 2, RESTORE_RETRY_MAX_MS);
      }
    };
    restoreRef.current = restore;
    restore();
    return () => clearTimeout(retryTimer);
  }, []);

  // Retry now (offline screen button) — resets nothing else; a success clears
  // `offline` and the app renders as normal.
  const retryConnection = useCallback(() => { restoreRef.current?.(); }, []);

  const login = useCallback(async (username, password) => {
    let data = await api.login({ username, password });
    // The account requires a passkey after the password (console › Passkeys). The
    // passkey sign-in is a complete login on its own, so just run it.
    if (data.requires_passkey) {
      if (!passkeysSupported()) {
        throw new Error('This account needs its passkey to sign in. Use a browser that has it, or link this device instead.');
      }
      data = await signInWithPasskey();
    }
    api.setToken(data.token);
    const acct = await api.getAccount();
    log.info('Auth', `Login succeeded user=${acct.account?.username || 'unknown'} orgs=${(acct.organizations || []).length}`)
    writeCachedAccount(acct);
    announceAuth(AUTH_SIGNED_IN, acct.account?.id);
    adoptDeviceTimezone(acct.account);
    setAuthState({
      user: acct.account,
      organizations: acct.organizations || [],
      currentOrgSlug: acct.current_org_slug,
      loading: false,
    });
    return { ...data, currentOrgSlug: acct.current_org_slug };
  }, []);

  const signup = useCallback(async (params) => {
    const data = await api.signup(params);
    api.setToken(data.token);
    writeCachedAccount(data);
    announceAuth(AUTH_SIGNED_IN, data.user?.id);
    setAuthState({ user: data.user, loading: false });
    return data;
  }, []);

  // Re-pull the account + orgs (e.g. after an org rename) so app-wide surfaces
  // that read org.name — the workspace tab, headers — reflect the change.
  const refreshAccount = useCallback(async () => {
    try {
      const data = await api.getAccount();
      writeCachedAccount(data);
      setAuthState((s) => ({
        ...s,
        user: data.account || data.user,
        organizations: data.organizations || [],
        currentOrgSlug: data.current_org_slug,
        loading: false,
      }));
    } catch (e) {
      log.warn('Auth', `refreshAccount failed: ${e?.message || e}`);
    }
  }, []);

  const logout = useCallback(async () => {
    log.info('Auth', 'Logging out')
    const leaving = authStateRef.current.user?.id;
    loggingOutRef.current = true; // a request caught mid-logout gets a 401: that isn't being signed out on you
    try { await api.logout(); } catch { /* ignore logout errors */ }
    // Tear down the credential vault session (drop the DEK + local state) so a
    // different inbox2 account signing in next can't upload into this one's vault
    // (docs/E2EE.md). Desktop-only; best-effort.
    try {
      const { isTauri } = await import('../lib/tauri');
      if (isTauri()) {
        const { invoke } = await import('@tauri-apps/api/core');
        await invoke('clear_vault_session');
      }
    } catch { /* engine not reachable */ }
    // Disk exact views converted on this device belong to this account (spec F5b); the engine stays.
    try { await (await import('../lib/disk/engine/conversions')).clearAllConversions(); } catch { /* storage blocked */ }
    // Sealed Disk keys live in memory and in the Disk service worker (6.11): drop both.
    try { await (await import('../stores/sealedStore')).default.getState().clear(); } catch { /* no worker */ }
    api.setToken(null);
    clearCachedAccount();
    setAuthState({ user: null, loading: false });
    // Now, not after the render: a signal landing between the two would see the old user.
    authStateRef.current = { ...authStateRef.current, user: null };
    loggingOutRef.current = false;
    // Every other tab of this origin learns it now, not on its next request.
    announceAuth(AUTH_SIGNED_OUT, leaving);
  }, []);

  // ── The one signed-out experience (lib/authBroadcast.js, components/SignedOutScreen) ──
  // Another tab signed out, a request got a 401, or an admin revoked access: this
  // tab drops its token, cached account, sealed Disk keys (and its own service
  // worker entries) and live channels at once, and puts up a blocking screen
  // over the page instead of bouncing to /login mid-task. The page stays mounted
  // behind it (inert) so unsaved editor text can be copied; the account object
  // stays in memory only for that, and "Sign in again" reloads through
  // /login?next= back to this URL. No user or nothing to protect: ignored.
  const [unsaved, setUnsaved] = useState([]);

  const enterSignedOut = useCallback((reason) => {
    if (!authStateRef.current.user) {
      // Nobody was signed in here (boot, login page): nothing to show over.
      api.setToken(null);
      clearCachedAccount();
      setAuthState({ user: null, organizations: [], currentOrgSlug: null, loading: false });
      return;
    }
    if (signedOutRef.current || loggingOutRef.current || IGNORES_AUTH_SIGNAL()) return;
    api.setToken(null);
    clearCachedAccount();
    import('../stores/sealedStore').then((m) => m.default.getState().clear()).catch(() => {});
    import('../lib/disk/engine/conversions').then((m) => m.clearAllConversions()).catch(() => {});
    orgLiveMail.reset();
    mxMirror.reset();
    pushSync._dropChannel?.();
    pauseCable();
    setUnsaved(unsavedWork());
    setSignedOut(reason);
  }, []);

  // While the screen is up, keep its list of unsaved work current.
  useEffect(() => (signedOut ? onUnsavedChange(() => setUnsaved(unsavedWork())) : undefined), [signedOut]);

  // The same account signed in again in another tab: pick its session up and carry on.
  const resumeSignedIn = useCallback(async () => {
    const token = await getSecret(CLOUD_AUTH_TOKEN).catch(() => null); // dev and desktop; prod web rides the cookie
    if (token) api.token = token;
    try {
      const data = await api.getAccount();
      writeCachedAccount(data);
      setAuthState((s) => ({ ...s, user: data.account || data.user, organizations: data.organizations || [], currentOrgSlug: data.current_org_slug, offline: false, loading: false }));
      resumeCable();
      setSignedOut(null);
    } catch (e) {
      log.warn('Auth', `resuming after another tab signed in failed: ${e?.message || e}`);
    }
  }, []);

  useEffect(() => onAuthBroadcast((msg) => {
    if (IGNORES_AUTH_SIGNAL()) return;
    const tab = { userId: authStateRef.current.user?.id ?? null, signedOut: !!signedOutRef.current };
    const what = reactionTo(tab, msg);
    if (what === 'sign-out') enterSignedOut('elsewhere');
    else if (what === 'resume') resumeSignedIn();
    else if (what === 'reload') window.location.assign('/'); // another account: its home, never this one's page
  }), [enterSignedOut, resumeSignedIn]);

  const signInAgain = useCallback(() => {
    const here = `${window.location.pathname}${window.location.search}${window.location.hash}`;
    window.location.assign(`/login?next=${encodeURIComponent(here)}`);
  }, []);

  // The screen takes the skin of the page it covers (read when it shows; the page is inert behind it).
  const skin = signedOut && /^\/(console|onboarding|admin)\b/.test(window.location.pathname) ? 'management' : 'aero';

  // Real-time forced sign-out: an admin revoked this user's access. The server
  // already destroyed the session, so just clear local state — protected routes
  // then redirect to login. No api.logout (the token is already dead).
  const forceLogout = useCallback((reason) => {
    log.warn('Auth', `Access revoked (${reason || 'revoked'}) — signing out`)
    const leaving = authStateRef.current.user?.id;
    // The session is gone everywhere in this browser: the other tabs show the screen too.
    if (leaving) announceAuth(AUTH_SIGNED_OUT, leaving);
    enterSignedOut(reason === 'session expired' ? 'expired' : 'revoked');
  }, [enterSignedOut]);

  // Sealed Disk keys belong to one signed-in account: whenever this tab's user goes
  // away or changes (sign-out, forced sign-out, session expiry, account switch), this
  // tab drops its keys and its own entries in the Disk service worker (6.11). Other
  // tabs do the same at once: a sign-out or sign-in is broadcast (lib/authBroadcast.js).
  const sealedUser = useRef(undefined);
  useEffect(() => {
    const now = authState.loading ? sealedUser.current : authState.user?.id ?? null;
    if (sealedUser.current !== undefined && now !== sealedUser.current) {
      import('../stores/sealedStore').then((m) => m.default.getState().clear()).catch(() => {});
    }
    sealedUser.current = now;
  }, [authState.user?.id, authState.loading]);

  // A 401 on any normal request (api.js dispatches SESSION_EXPIRED_EVENT) means
  // the session died mid-use — sign out so ProtectedRoute redirects to login,
  // rather than leaving the app on a silently-failing dead session.
  useEffect(() => {
    const onExpired = () => forceLogout('session expired');
    window.addEventListener(SESSION_EXPIRED_EVENT, onExpired);
    return () => window.removeEventListener(SESSION_EXPIRED_EVENT, onExpired);
  }, [forceLogout]);

  // A bearer adopted mid-session (device-link from Settings/Setup, pasted ink_
  // key) — pull the account + orgs now so the MX workspace surfaces without a
  // webview reload.
  useEffect(() => {
    const onAdopted = () => refreshAccount();
    window.addEventListener(TOKEN_ADOPTED_EVENT, onAdopted);
    return () => window.removeEventListener(TOKEN_ADOPTED_EVENT, onAdopted);
  }, [refreshAccount]);

  // Keep a live per-user channel open while authenticated so a revoke kick lands
  // instantly (the DB session delete is the backstop on the next request).
  useEffect(() => {
    if (IS_NOTIFICATION_POPUP) return undefined;
    if (!authState.user) {
      // Positive trace for the OFF state. Everything cloud-backed hangs off this
      // one condition — no PushSyncChannel means no realtime push and no renewal
      // of the provider push subscriptions — and previously it left no log at
      // all, so the only visible symptom was "the desktop is a minute behind".
      //
      // Only once auth has SETTLED. This effect also runs on mount, while the
      // bearer is still hydrating, so warning unconditionally cried wolf on
      // every single boot — and a warning that's normal is one nobody reads.
      if (!authState.loading) {
        log.warn('PushSync', 'not authenticated — PushSyncChannel not opened (no realtime cloud push)');
      }
      return undefined;
    }
    pushSync.onForceLogout((data) => forceLogout(data?.reason));
    pushSync.ensureSessionListener();
    return undefined;
  }, [authState.user, authState.loading, forceLogout]);

  // Open a per-org ActionCable stream for each accessible org so new MX mail
  // refreshes the inbox in real time (org `id` is the public key). Tear the
  // streams down on sign-out. See lib/orgLiveMail.js.
  useEffect(() => {
    if (IS_NOTIFICATION_POPUP) return undefined;
    if (!authState.user) { orgLiveMail.reset(); mxMirror.reset(); return undefined; }
    const orgKeys = (authState.organizations || []).map((o) => o.id);
    orgLiveMail.syncOrgs(orgKeys);
    // Desktop: mirror these orgs' mail into local SQLite (docs/MX-Sync.md).
    mxMirror.watch(orgKeys, authState.user.id);
    return undefined;
  }, [authState.user, authState.organizations]);

  // A domain added/removed/status-changed out-of-band (console, admin CLI, another
  // session) broadcasts `domain_changed` on the org channel — re-pull /account so
  // the new workspace tab appears without a webview reload.
  useEffect(() => {
    if (!authState.user) return undefined;
    return orgLiveMail.onDomainChanged(refreshAccount);
  }, [authState.user, refreshAccount]);

  // The org the user is currently acting in (matches the URL slug, else the
  // first org). Its `role` drives admin-only UI gating across the app.
  const currentOrg = useMemo(() => {
    const orgs = authState.organizations || [];
    return orgs.find((o) => o.slug === authState.currentOrgSlug) || orgs[0] || null;
  }, [authState.organizations, authState.currentOrgSlug]);

  const role = currentOrg?.role || null;

  const value = useMemo(() => ({
    user: authState.user,
    organizations: authState.organizations,
    currentOrgSlug: authState.currentOrgSlug,
    currentOrg,
    role,
    isAdmin: isAdminRole(role),
    isOwner: isOwnerRole(role),
    loading: authState.loading,
    // The API is unreachable (not a dead session) — routes render the offline
    // screen instead of bouncing to /login.
    offline: authState.offline,
    retryConnection,
    login,
    signup,
    logout,
    refreshAccount,
  }), [authState, currentOrg, role, login, signup, logout, refreshAccount, retryConnection]);

  return (
    <AuthContext.Provider value={value}>
      {children}
      {signedOut && <SignedOutScreen reason={signedOut} unsaved={unsaved} skin={skin} onSignIn={signInAgain} />}
    </AuthContext.Provider>
  );
}
