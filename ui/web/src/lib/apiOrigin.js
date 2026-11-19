// Where the cloud API lives, relative to the web app.
//
// Same-origin by default. In dev the Vite proxy forwards `/api` + `/cable` to
// the API, and inside the desktop/in-cluster builds the app and API share an
// origin — so requests stay relative ('/api/v1', `${host}/cable`) and `API_ORIGIN`
// is empty.
//
// On Cloudflare Pages the web app (mail.inbox2.com) is a DIFFERENT origin from
// the API (api.inbox2.com). Pages can't proxy to an external origin (and can't
// proxy WebSockets at all), so the Pages build is produced with `--mode pages`,
// which injects `VITE_API_ORIGIN` (see .env.pages). The app then talks to the
// API cross-origin. Auth persists via the HttpOnly `inbox2_session` cookie: it is
// same-site (mail.inbox2.com and api.inbox2.com share the inbox2.com registrable
// domain), so its SameSite=Lax cookie rides the cross-subdomain XHR after refresh.
// The API must allow this origin via FRONTEND_URL (CORS, with credentials),
// CABLE_ALLOWED_ORIGINS (ActionCable), and WEBAUTHN_ORIGIN.
//
// Only ever read through here — never inline `import.meta.env.VITE_API_ORIGIN`.
export const API_ORIGIN = (import.meta.env.VITE_API_ORIGIN || '').replace(/\/+$/, '');

// The API base to hand to native code (the Rust engine, the device-link
// exchange) — always ABSOLUTE, because Rust can't resolve a relative path.
//
// `window.location.origin` alone is wrong in a bundled desktop app: the webview
// origin there is the custom scheme (tauri://localhost), which no HTTP client can
// reach. The desktop bundles bake VITE_API_ORIGIN at build time (see the
// `beforeBuildCommand` in tauri.conf.json / tauri.dev.conf.json), so API_ORIGIN
// wins whenever it is set and the location origin is only the same-origin
// fallback (dev via the Vite proxy, in-cluster web).
export function apiBaseUrl() {
  const origin = API_ORIGIN || (typeof window !== 'undefined' ? window.location.origin : '');
  return `${origin}/api/v1`;
}

// WebSocket origin (wss://api.inbox2.com) derived from API_ORIGIN. Empty when
// same-origin, so callers fall back to window.location.
export function cableOrigin() {
  if (!API_ORIGIN) return null;
  const url = new URL(API_ORIGIN);
  const protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return { protocol, host: url.host };
}
