// Shared handling for the personal API key (ink_…) that standalone desktop
// clients use to authenticate cloud features (image proxy, push). It's stored in
// the portable secret store via api.setToken (CLOUD_AUTH_TOKEN), exactly like a
// session token — no localStorage.
import api, { TOKEN_ADOPTED_EVENT } from './api';

export const API_KEY_PREFIX = 'ink_';

export function isApiKey(value) {
  return typeof value === 'string' && value.trim().startsWith(API_KEY_PREFIX);
}

// The currently-stored bearer (api key or session token). Async — the secret
// store is the source of truth.
export function currentToken() {
  return api.getToken();
}

// Validate + persist. Returns true on success, false if it isn't an ink_ key.
// Announces the adoption so AuthProvider re-pulls the account + orgs — the MX
// tabs/inbox appear immediately instead of waiting for a webview reload.
export function saveApiKey(value) {
  if (!isApiKey(value)) return false;
  api.setToken(value.trim());
  window.dispatchEvent(new CustomEvent(TOKEN_ADOPTED_EVENT));
  return true;
}

export function clearApiKey() {
  api.setToken(null);
}
