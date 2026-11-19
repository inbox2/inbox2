// Device-link (loopback + PKCE) client helpers — the OAuth-style "link this
// device to your inbox2 account" flow. See docs/Device-Link.md and the Rails
// DeviceLinkController.
//
// Two roles share this module:
//   • The WEB approval page (/link) — the browser surface where a logged-in user
//     approves a link request and is 302'd back to the client's loopback. It only
//     needs `parseLinkParams` + `api.authorizeDeviceLink` + `buildRedirect`.
//   • The DESKTOP initiator — `startDesktopDeviceLink()` hands the whole loopback
//     dance to the Rust `start_device_link` command (it binds 127.0.0.1, opens
//     the browser, exchanges the code, and persists the minted ink_ key into the
//     engine's encrypted store). Mobile clients run the equivalent natively.
import { API_ORIGIN, apiBaseUrl } from './apiOrigin';
import { ACCOUNT_WEB_URL } from './webOrigin';

// Public origins for the link flow. The native loopback exchange must hit the
// REAL public API/web origins, never the in-app webview proxy origin (which is a
// custom protocol the system browser / a raw HTTP client can't reach). Overridable
// for local dev (e.g. VITE_ACCOUNT_URL=http://localhost:4173 — see webOrigin.js).
const PUBLIC_API_ORIGIN = (API_ORIGIN || import.meta.env.VITE_PUBLIC_API_ORIGIN || 'https://api.inbox2.com').replace(/\/+$/, '');

const PLATFORM_DESKTOP = 'desktop';
const PLATFORM_IOS = 'ios';
const PLATFORM_ANDROID = 'android';
const PLATFORM_CLI = 'cli';

// The browser approval page a client opens to start linking.
function accountLinkUrl() {
  return `${ACCOUNT_WEB_URL}/link`;
}

// The public API base the native exchange POSTs the code to.
function publicApiBase() {
  return `${PUBLIC_API_ORIGIN}/api/v1`;
}

// ── Web approval page ───────────────────────────────

// Read the link request the native client put in the /link query string.
export function parseLinkParams(search) {
  const sp = new URLSearchParams(search || '');
  return {
    deviceName: sp.get('device_name') || '',
    platform: sp.get('platform') || '',
    redirectUri: sp.get('redirect_uri') || '',
    state: sp.get('state') || '',
    codeChallenge: sp.get('code_challenge') || '',
    codeChallengeMethod: sp.get('code_challenge_method') || 'S256',
  };
}

// A request is only actionable if it carries a challenge + a loopback redirect.
export function linkParamsValid(p) {
  if (!p?.codeChallenge || !p?.redirectUri || !p?.platform) return false;
  try {
    const u = new URL(p.redirectUri);
    return ['127.0.0.1', 'localhost', '::1'].includes(u.hostname);
  } catch {
    return false;
  }
}

// Build the loopback URL the browser is sent back to once approved. The native
// listener pulls the one-time code (+ echoes state for CSRF) from here.
export function buildRedirect(redirectUri, code, state) {
  const u = new URL(redirectUri);
  u.searchParams.set('code', code);
  if (state) u.searchParams.set('state', state);
  return u.toString();
}

export function platformLabel(platform) {
  switch (platform) {
    case PLATFORM_DESKTOP: return 'Desktop app';
    case PLATFORM_IOS: return 'iPhone';
    case PLATFORM_ANDROID: return 'Android';
    case PLATFORM_CLI: return 'Command line';
    default: return 'a new device';
  }
}

// ── Desktop initiator ───────────────────────────────

// Run the full link flow from the desktop: Rust binds the loopback, opens the
// browser, exchanges the approved code, and persists the ink_ key. Resolves to
// { token, user }. Throws on cancel/timeout/exchange failure.
export async function startDesktopDeviceLink({ deviceName = '' } = {}) {
  const { invoke } = await import('@tauri-apps/api/core');
  const result = await invoke('start_device_link', {
    linkUrl: accountLinkUrl(),
    apiBase: publicApiBase(),
    deviceName,
  });
  // Push the freshly-minted bearer into the engine so cloud push arms immediately
  // (sync-manager.init already ran for this session and won't re-run). Mirrors the
  // apiBase sync-manager uses (the app/proxy origin), not the public exchange origin.
  if (result?.token && typeof window !== 'undefined') {
    try {
      await invoke('set_api_context', { apiBase: apiBaseUrl(), railsJwt: result.token });
    } catch { /* the Rust command also persists it; non-fatal */ }
  }
  return result;
}
