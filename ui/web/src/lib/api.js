import log from './log'
import { getSecret, setSecret, clearSecret } from './secretStore'
import { API_ORIGIN } from './apiOrigin'
import { isTauri } from './tauri'
import { scrubIfDemo, isDemoMode, DEMO_HIDDEN_SOURCE } from './demoData'
import { closeAlertsFor } from './alertDismiss'

// Relative in dev / desktop / in-cluster (same origin); absolute against the
// API origin on Cloudflare Pages (cross-origin). See apiOrigin.js.
const API_BASE = `${API_ORIGIN}/api/v1`;

// Cloud auth bearer. On DESKTOP it's a session token or personal ink_ API key,
// persisted in the engine's encrypted device-bound store (shared with the CLI).
// On the WEB build the session lives in an HttpOnly cookie set by Rails — never
// in JS/localStorage (XSS-exfil defence) — so the web never persists it here.
export const CLOUD_AUTH_TOKEN = 'cloud_auth_token';

// Dispatched when an authenticated request comes back 401 mid-session (dead/
// expired session). AuthProvider listens and signs the user out → redirect.
export const SESSION_EXPIRED_EVENT = 'inbox2:session-expired';

// Dispatched when a new bearer is adopted mid-session (device-link / pasted
// ink_ key). AuthProvider listens and re-pulls the account + orgs so the MX
// workspace surfaces immediately, without a webview reload.
export const TOKEN_ADOPTED_EVENT = 'inbox2:token-adopted';

// The engine's durable copy of the cloud bearer, read through the dedicated
// command (it reaches the bare `cloud_auth_token` entry that the kv: namespace
// cannot). Null on any failure — this is a fallback, never a hard dependency.
async function engineRailsToken() {
  try {
    const { invoke } = await import('@tauri-apps/api/core');
    return (await invoke('get_rails_token')) || null;
  } catch (e) {
    log.warn('Auth', `get_rails_token failed: ${e?.message || e}`);
    return null;
  }
}

// Error carrying an HTTP-ish status the caller can branch on (0 = network).
function statusError(message, status) {
  const error = new Error(message);
  error.status = status;
  return error;
}

class ApiClient {
  constructor() {
    this.token = null;
    if (isTauri()) {
      // Desktop: hydrate the bearer from the encrypted store, then fall back to
      // the engine's own durable copy.
      //
      // TWO NAMESPACES, ONE TOKEN. getSecret() goes through the webview KV
      // namespace, which the Tauri command and the RPC handler both rewrite to
      // `kv:<name>` — but the ENGINE persists the same bearer under the BARE
      // name `cloud_auth_token` (engine/mod.rs). So a store holding a perfectly
      // good engine-written token reads as empty here, canRestore goes false in
      // AuthProvider, and the app silently signs out of MX while local channels
      // keep syncing — which is exactly what a rebuilt production app looked
      // like: MX "lost", no PushSyncChannel, provider push subs left to lapse.
      // get_rails_token exists to bridge the two; nothing called it until now.
      this.ready = getSecret(CLOUD_AUTH_TOKEN)
        .then(async (t) => {
          if (t) { log.info('Auth', 'Bearer restored from webview secret store'); return t; }
          const durable = await engineRailsToken();
          if (durable) {
            log.info('Auth', 'Bearer restored from engine store (webview copy was empty)');
            // Re-seed the webview namespace so the next boot hits the fast path.
            setSecret(CLOUD_AUTH_TOKEN, durable);
          } else {
            log.warn('Auth', 'No bearer in webview store or engine store — cloud signed out');
          }
          return durable;
        })
        .then((t) => { this.token = this.token ?? (t || null); return this.token; })
        .catch((e) => { log.warn('Auth', `Bearer hydration failed: ${e?.message || e}`); return this.token; });
    } else if (import.meta.env.DEV) {
      // Local dev proxies to a remote API whose HttpOnly session cookie is
      // host-only + Secure, which http://localhost can't reliably store — so the
      // session would be lost on every reload (/console → /login). DEV-ONLY:
      // persist the bearer token (login response body) and restore it on cold
      // start. Prod web keeps the cookie-only, no-token-in-JS posture below.
      this.ready = getSecret(CLOUD_AUTH_TOKEN)
        .then((t) => { this.token = this.token ?? (t || null); return this.token; })
        .catch(() => this.token);
    } else {
      // Web (prod): the session is the HttpOnly cookie. Purge any legacy
      // localStorage bearer and rely on the cookie (sent via credentials:'include').
      clearSecret(CLOUD_AUTH_TOKEN);
      this.ready = Promise.resolve(null);
    }
  }

  // Async token accessor — waits for hydration on a cold start.
  async getToken() {
    return this.token ?? await this.ready;
  }

  setToken(token) {
    this.token = token || null;
    // Desktop + DEV web persist the bearer (DEV web: survive reloads when the
    // remote cookie can't bind to localhost). Prod web relies on the cookie only.
    if (isTauri() || import.meta.env.DEV) {
      if (token) setSecret(CLOUD_AUTH_TOKEN, token);
      else clearSecret(CLOUD_AUTH_TOKEN);
    } else if (!token) {
      clearSecret(CLOUD_AUTH_TOKEN); // belt-and-suspenders: clear any legacy copy
    }
  }

  async request(method, path, body = null) {
    // Demo mode is read-only against MX: no sends, no status write-backs, no
    // settings changes. Refused here rather than per call site — this is the one
    // door every MX write goes through. Auth (login/refresh) still has to work.
    if (method !== 'GET' && isDemoMode() && !path.startsWith('/auth/')) {
      log.warn('API', `${method} ${path} blocked — demo data is on`);
      throw statusError('Demo data is on, so nothing is saved. Press ⇧⌘D to turn it off.', 403);
    }

    const headers = { 'Content-Type': 'application/json' };
    const token = await this.getToken();
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    // Send the HttpOnly session cookie on cross-origin (Pages → api.inbox2.com)
    // requests; harmless same-origin. CORS already allows credentials.
    const options = { method, headers, credentials: 'include' };
    if (body) {
      options.body = JSON.stringify(body);
    }

    log.debug('API', `${method} ${path}`)
    const t0 = performance.now()

    let response;
    try {
      response = await fetch(`${API_BASE}${path}`, options);
    } catch {
      log.error('API', `Network error: ${method} ${path}`)
      const error = new Error("Can't reach inbox2. Check your connection.");
      error.status = 0;
      throw error;
    }

    const elapsed = Math.round(performance.now() - t0)

    let data = null;
    if (response.status !== 204) {
      const text = await response.text();
      if (text) {
        try {
          data = JSON.parse(text);
        } catch {
          log.error('API', `Invalid JSON: ${method} ${path} status=${response.status}`)
          const error = new Error(`Something went wrong on our side (${response.status}).`);
          error.status = response.status;
          throw error;
        }
      }
    }

    if (!response.ok) {
      const logFn = response.status >= 500 ? log.error : log.warn
      logFn('API', `HTTP ${response.status}: ${method} ${path} (${elapsed}ms)`)
      // A 401 on a normal request (not the login/auth endpoints, where 401 means
      // "wrong credentials") = the session died mid-use. Clear it and signal the
      // app to sign out + redirect, instead of every call site silently failing.
      // Only a request that actually carried credentials proves that: on the web
      // the cookie always rides along, but a desktop request without a bearer
      // 401s by definition (e.g. restored UI state firing org calls while signed
      // out) — treating that as "session died" wiped the encrypted token store.
      const carriedAuth = !!token || !isTauri();
      if (response.status === 401 && !path.startsWith('/auth/') && carriedAuth) {
        this.setToken(null);
        if (typeof window !== 'undefined') {
          window.dispatchEvent(new CustomEvent(SESSION_EXPIRED_EVENT));
        }
      }
      const error = new Error(data?.errors?.[0]?.message || `Something went wrong (${response.status}). Try again.`);
      error.status = response.status;
      error.data = data;
      throw error;
    }

    if (elapsed > 3000) {
      log.warn('API', `Slow response: ${method} ${path} took ${elapsed}ms`)
    }

    // Demo mode: MX reads come back with fake people and mail (lib/demoData.js).
    // Only GETs — a scrubbed write response would echo fake values back into the
    // UI's local state as if the server had stored them.
    return method === 'GET' ? scrubIfDemo(data) : data;
  }

  // The API's public base (absolute), for URLs handed to third parties (SAML metadata).
  get baseUrl() { return API_BASE; }

  get(path) { return this.request('GET', path); }
  post(path, body) { return this.request('POST', path, body); }
  patch(path, body) { return this.request('PATCH', path, body); }
  put(path, body) { return this.request('PUT', path, body); }
  delete(path) { return this.request('DELETE', path); }

  async upload(path, formData) {
    // Uploads bypass request(), so the demo-mode read-only rule needs saying here too.
    if (isDemoMode()) {
      log.warn('API', `Upload ${path} blocked — demo data is on`);
      throw statusError('Demo data is on, so nothing is uploaded. Press ⇧⌘D to turn it off.', 403);
    }
    const headers = {};
    const token = await this.getToken();
    if (token) headers['Authorization'] = `Bearer ${token}`;

    log.info('API', `Upload POST ${path}`)
    const response = await fetch(`${API_BASE}${path}`, {
      method: 'POST',
      headers,
      credentials: 'include',
      body: formData,
    });

    const data = response.status !== 204 ? await response.json() : null;

    if (!response.ok) {
      log.error('API', `Upload failed: POST ${path} status=${response.status}`)
      const error = new Error(data?.errors?.[0]?.message || `Couldn't upload the file (${response.status}).`);
      error.status = response.status;
      throw error;
    }

    return data;
  }

  // Auth
  signup(params) { return this.post('/auth/signup', params); }
  login(params) { return this.post('/auth/login', params); }
  logout() { return this.post('/auth/logout'); }
  // Passkeys (WebAuthn, A1.9) — the browser ceremony lives in lib/passkeys.js.
  passkeyRegistrationOptions(password) { return this.post('/auth/webauthn/registration-options', { password }); }
  registerPasskey(credential, nickname) { return this.post('/auth/webauthn/register', { credential, nickname }); }
  passkeyLoginOptions() { return this.get('/auth/webauthn/authenticate-options'); }
  passkeyLogin(credential) { return this.post('/auth/webauthn/authenticate', { credential }); }
  listPasskeys() { return this.get('/auth/webauthn/credentials'); }
  setPasskeyRequired(required, password) { return this.put('/auth/webauthn/requirement', { required, password }); }
  deletePasskey(id) { return this.delete(`/auth/webauthn/credentials/${encodeURIComponent(id)}`); }
  oauthProviders() { return this.get('/auth/oauth/providers'); }
  oauthCallback(params) { return this.post('/auth/oauth/callback', params); }
  // SAML SSO (spec 2.1.7). `org` is the org key or slug. initiate → the IdP URL to
  // navigate to; the IdP posts back to the API, which bounces the browser to
  // /sso/saml/callback?ticket=… and exchange turns that one-time ticket into a session.
  samlInitiate(org) { return this.get(`/orgs/${encodeURIComponent(org)}/saml/initiate`); }
  samlExchange(ticket) { return this.post('/auth/saml/exchange', { ticket }); }
  samlConfig(orgId) { return this.get(`/orgs/${orgId}/saml`); }
  saveSamlConfig(orgId, params) { return this.put(`/orgs/${orgId}/saml`, params); }
  deleteSamlConfig(orgId) { return this.delete(`/orgs/${orgId}/saml`); }
  samlIdentity(orgId) { return this.get(`/orgs/${orgId}/saml/identity`); }
  samlLink(orgId) { return this.post(`/orgs/${orgId}/saml/link`); }
  samlUnlink(orgId) { return this.delete(`/orgs/${orgId}/saml/identity`); }
  resetPasswordRequest(email) { return this.post('/auth/password/reset-request', { email }); }
  resetPassword(params) { return this.post('/auth/password/reset', params); }
  // Device-link approval (web /link page, session/cookie authed). Mints a one-time
  // PKCE-bound code the browser then 302s back to the client's loopback listener.
  authorizeDeviceLink(params) { return this.post('/auth/device-link/authorize', params); }
  acceptInvite(params) { return this.post('/members/accept-invite', params); }

  // Waitlist (public, pre-launch invite-only). Submit always 202s (dedupe never
  // leaks existence); config reports the gate state + Turnstile site key; invite
  // lookup prefills the account-creation screen from a redeemable token.
  waitlistSignup(params) { return this.post('/waitlist', params); }
  waitlistConfig() { return this.get('/waitlist/config'); }
  waitlistInviteLookup(token) { return this.get(`/waitlist/invite?token=${encodeURIComponent(token)}`); }

  // Account
  getAccount() { return this.get('/account'); }

  // Touch Strip (docs/Touch-Strip.md): public feeds + the synced layout.
  stripQuotes(symbols) { return this.get(`/strip/quotes?symbols=${encodeURIComponent(symbols.join(','))}`); }
  stripSymbols(q) { return this.get(`/strip/symbols?q=${encodeURIComponent(q)}`); }
  stripPlaces(q) { return this.get(`/strip/places?q=${encodeURIComponent(q)}`); }
  stripWeather({ lat, lon, place } = {}) {
    const qs = lat != null && lon != null ? `?${new URLSearchParams({ lat, lon, place: place || '' })}` : '';
    return this.get(`/strip/weather${qs}`);
  }
  stripIp() { return this.get('/strip/ip'); }
  stripNews(urls) { return this.get(`/strip/news?${urls.map((u) => `feeds[]=${encodeURIComponent(u)}`).join('&')}`); }
  getTouchStrip() { return this.get('/account/touch-strip'); }
  saveTouchStrip(config) { return this.put('/account/touch-strip', { touch_strip: config }); }
  uploadAvatar(file) { const fd = new FormData(); fd.append('file', file); return this.upload('/account/avatar', fd); }
  updateContactEmail(billing_email) { return this.put('/account/billing-email', { billing_email }); }
  confirmContactEmail(token) { return this.post('/auth/confirm-email', { token }); }
  changePassword({ current_password, password }) { return this.put('/account/password', { current_password, password }); }

  // Personal API keys (A17). The raw token is returned by createApiKey once only.
  listApiKeys() { return this.get('/account/api-keys'); }
  createApiKey({ name, scopes }) { return this.post('/account/api-keys', { name, scopes }); }
  revokeApiKey(key) { return this.delete(`/account/api-keys/${key}`); }

  // Sending API, console side (docs/ESP.md). Org-scoped, admin only. The raw
  // token comes back from createEspKey once.
  listEspKeys(orgId) { return this.get(`/orgs/${orgId}/esp/keys`); }
  createEspKey(orgId, name) { return this.post(`/orgs/${orgId}/esp/keys`, { name }); }
  revokeEspKey(orgId, key) { return this.delete(`/orgs/${orgId}/esp/keys/${key}`); }
  listEspDomains(orgId) { return this.get(`/orgs/${orgId}/esp/domains`); }
  createEspDomain(orgId, domain) { return this.post(`/orgs/${orgId}/esp/domains`, { domain }); }
  verifyEspDomain(orgId, key) { return this.post(`/orgs/${orgId}/esp/domains/${key}/verify`); }
  deleteEspDomain(orgId, key) { return this.delete(`/orgs/${orgId}/esp/domains/${key}`); }
  listEspEmails(orgId, page = 1) { return this.get(`/orgs/${orgId}/esp/emails?page=${page}`); }
  espUsage(orgId) { return this.get(`/orgs/${orgId}/esp/usage`); }

  // Mail clients (docs/Mail-Clients.md): the settings to type into a client and
  // the member's own app passwords. The password comes back once.
  mailClientSettings(orgId) { return this.get(`/orgs/${orgId}/mail-client`); }
  listSignatures(orgId) { return this.get(`/orgs/${orgId}/signatures`); }
  createSignature(orgId, body) { return this.post(`/orgs/${orgId}/signatures`, body); }
  updateSignature(orgId, key, body) { return this.patch(`/orgs/${orgId}/signatures/${key}`, body); }
  deleteSignature(orgId, key) { return this.delete(`/orgs/${orgId}/signatures/${key}`); }
  listMailClientPasswords(orgId) { return this.get(`/orgs/${orgId}/mail-client/passwords`); }
  createMailClientPassword(orgId, name) { return this.post(`/orgs/${orgId}/mail-client/passwords`, { name }); }
  deleteMailClientPassword(orgId, key) { return this.delete(`/orgs/${orgId}/mail-client/passwords/${key}`); }

  // Registered applications (docs/App-OAuth.md) — third-party apps allowed to
  // broker Google/Microsoft OAuth through inbox2. Org-scoped, admin only.
  listOauthApps(orgId) { return this.get(`/orgs/${orgId}/oauth-apps`); }
  createOauthApp(orgId, payload) { return this.post(`/orgs/${orgId}/oauth-apps`, payload); }
  updateOauthApp(orgId, appId, payload) { return this.patch(`/orgs/${orgId}/oauth-apps/${appId}`, payload); }
  deleteOauthApp(orgId, appId) { return this.delete(`/orgs/${orgId}/oauth-apps/${appId}`); }
  uploadOauthAppIcon(orgId, appId, file) { const fd = new FormData(); fd.append('file', file); return this.upload(`/orgs/${orgId}/oauth-apps/${appId}/icon`, fd); }

  // The consent screen (/oauth/consent) — public: whoever is granting access to
  // their mailbox is not necessarily an inbox2 user.
  getAppOauthConsent(flow) { return this.get(`/auth/app-oauth/consent?flow=${encodeURIComponent(flow)}`); }

  // Zero-knowledge credential vault (docs/E2EE.md). Server returns only metadata
  // (provider + email) — never the ciphertext blob — for the management card.
  listStoredCredentials() { return this.get('/stored-credentials'); }
  deleteStoredCredential(key) { return this.delete(`/stored-credentials/${key}`); }

  // Organisation data export (docs/Reference-Implementation.md "Data export").
  listDataExports(orgId) { return this.get(`/orgs/${orgId}/exports`); }
  // Mail import from Google Workspace / Microsoft 365 (docs/plans/mail-import.md)
  listMailImports(orgId) { return this.get(`/orgs/${orgId}/mail-imports`); }
  startMailImport(orgId, provider, domainId) { return this.post(`/orgs/${orgId}/mail-imports`, { provider, domain_id: domainId }); }
  resumeMailImport(orgId, id) { return this.post(`/orgs/${orgId}/mail-imports/${id}/resume`); }
  cancelMailImport(orgId, id) { return this.delete(`/orgs/${orgId}/mail-imports/${id}`); }
  listMyMailImports(orgId) { return this.get(`/orgs/${orgId}/my-mail-imports`); }
  startMyMailImport(orgId, mailboxId, nodeId) { return this.post(`/orgs/${orgId}/my-mail-imports`, { mailbox_id: mailboxId, node_id: nodeId }); }
  resumeMyMailImport(orgId, id) { return this.post(`/orgs/${orgId}/my-mail-imports/${id}/resume`); }
  cancelMyMailImport(orgId, id) { return this.delete(`/orgs/${orgId}/my-mail-imports/${id}`); }
  startDataExport(orgId) { return this.post(`/orgs/${orgId}/export`); }

  // Organizations
  getOrg(orgId) { return this.get(`/orgs/${orgId}`); }
  getOrgDns(orgId) { return this.get(`/orgs/${orgId}/dns`); }
  verifyOrgDns(orgId) { return this.post(`/orgs/${orgId}/dns/verify`); }
  updateOrg(orgId, attrs) { return this.patch(`/orgs/${orgId}`, attrs); }
  deleteOrg(orgId) { return this.delete(`/orgs/${orgId}`); }
  fetchOrgIcon(orgId) { return this.post(`/orgs/${orgId}/icon/fetch`); }
  inviteMx(params) { return this.post('/members/invite-mx', params); }
  uploadOrgIcon(orgId, file) { const fd = new FormData(); fd.append('file', file); return this.upload(`/orgs/${orgId}/icon`, fd); }
  uploadDomainIcon(orgId, domainKey, file) { const fd = new FormData(); fd.append('file', file); return this.upload(`/orgs/${orgId}/domains/${domainKey}/icon`, fd); }
  uploadOrgLogo(orgId, file) { const fd = new FormData(); fd.append('file', file); return this.upload(`/orgs/${orgId}/logo`, fd); }
  getOnboarding(orgId) { return this.get(`/orgs/${orgId}/onboarding`); }

  // Deliverability — choose inbox2 SMTP vs a customer-owned ESP (per domain/org).
  getDeliverability(orgId) { return this.get(`/orgs/${orgId}/deliverability`); }
  updateDeliverability(orgId, payload) { return this.put(`/orgs/${orgId}/deliverability`, payload); }
  testDeliverability(orgId, payload) { return this.post(`/orgs/${orgId}/deliverability/test`, payload); }

  // Conversations
  getConversations(orgId, params = {}) {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) {
      if (Array.isArray(v)) v.forEach(item => qs.append(`${k}[]`, item));
      else if (v != null) qs.append(k, v);
    }
    const query = qs.toString();
    return this.get(`/orgs/${orgId}/conversations${query ? `?${query}` : ''}`);
  }
  // Exact unread count for the org's open pool, optionally narrowed to one
  // domain/space. The ONLY correct source for a badge — counting unread rows out
  // of getConversations caps the number at the page size (25).
  getUnreadCount(orgId, params = {}) {
    const qs = new URLSearchParams(Object.entries(params).filter(([, v]) => v != null)).toString();
    return this.get(`/orgs/${orgId}/conversations/unread-count${qs ? `?${qs}` : ''}`);
  }
  // Address folders (AddressFolders on the API): one domain's folder tree, and
  // the member's Show in Inbox / bell per folder (`address` = full address or "inbox").
  getFolders(orgId, domainKey) { return this.get(`/orgs/${orgId}/folders?domain=${encodeURIComponent(domainKey)}`); }
  updateFolderPrefs(orgId, prefs) { return this.patch(`/orgs/${orgId}/folders/prefs`, prefs); }
  // Binary GET for a server-relative API path (`/orgs/…/attachments/…`), used by
  // attachment download. `request()` always parses JSON, and an attachment is
  // bytes; a plain <a href> can't carry the bearer the desktop authenticates
  // with. `redirect: 'follow'` is the default and is what we want — the endpoint
  // 302s to a short-lived presigned S3 URL, which must be fetched WITHOUT our
  // Authorization header (S3 rejects a request carrying both), so the browser's
  // own redirect handling does the right thing here and a manual re-fetch does not.
  async getBlob(path) {
    const headers = {};
    const token = await this.getToken();
    if (token) headers['Authorization'] = `Bearer ${token}`;
    const url = path.startsWith('/api/') ? `${API_ORIGIN}${path}` : `${API_BASE}${path}`;
    const response = await fetch(url, { headers, credentials: 'include' });
    if (!response.ok) {
      const error = new Error(`Couldn't download the file (${response.status})`);
      error.status = response.status;
      throw error;
    }
    return new Uint8Array(await response.arrayBuffer());
  }

  getConversation(orgId, convId) { return this.get(`/orgs/${orgId}/conversations/${convId}`); }
  updateConversation(orgId, convId, params) { return this.patch(`/orgs/${orgId}/conversations/${convId}`, params); }
  async bulkConversations(orgId, conversationIds, actionName) {
    const res = await this.post(`/orgs/${orgId}/conversations/bulk`, { conversation_ids: conversationIds, action_name: actionName });
    closeAlertsFor(conversationIds, actionName);
    return res;
  }
  // Permanently wipe a disposable folder (status = 'trash' | 'spam'). Irreversible.
  emptyFolder(orgId, status) {
    return this.post(`/orgs/${orgId}/conversations/empty`, { status });
  }
  // Move a thread into a Space (spaceId = spc_… key, or null to clear/untriage).
  updateConversationSpace(orgId, convId, spaceId) {
    return this.put(`/orgs/${orgId}/conversations/${convId}/space`, { space_id: spaceId });
  }
  // Manually set a thread's Jev label (an enabled triage-label slug). Sticks
  // until the next inbound message, when Jev judges the thread again.
  setConversationTriageLabel(orgId, convId, label) {
    return this.put(`/orgs/${orgId}/conversations/${convId}/triage-label`, { label });
  }
  // Ask Jev again (label + priority; the Space too while the thread has none). 202.
  retriageConversation(orgId, convId) {
    return this.post(`/orgs/${orgId}/conversations/${convId}/retriage`);
  }

  // Views
  getViews(orgId) { return this.get(`/orgs/${orgId}/views`); }

  // Mailboxes — Command Center
  getMailboxStats(orgId) { return this.get(`/orgs/${orgId}/mailboxes/stats`); }
  getMailboxPair(orgId, source, target) {
    return this.get(`/orgs/${orgId}/mailboxes/pair?source=${encodeURIComponent(source)}&target=${encodeURIComponent(target)}`);
  }

  // Lore ontology — mined entities + the entity graph (docs/Ontology.md)
  getLoreGraph(orgId) { return this.get(`/orgs/${orgId}/lore/graph`); }
  getLoreEntities(orgId, params = {}) {
    const qs = new URLSearchParams(Object.entries(params).filter(([, v]) => v)).toString();
    return this.get(`/orgs/${orgId}/lore/entities${qs ? `?${qs}` : ''}`);
  }
  getLoreEntity(orgId, id) { return this.get(`/orgs/${orgId}/lore/entities/${encodeURIComponent(id)}`); }
  updateLoreEntity(orgId, id, body) { return this.patch(`/orgs/${orgId}/lore/entities/${encodeURIComponent(id)}`, body); }
  deleteLoreEntity(orgId, id) { return this.delete(`/orgs/${orgId}/lore/entities/${encodeURIComponent(id)}`); }
  mergeLoreEntity(orgId, id, into) { return this.post(`/orgs/${orgId}/lore/entities/${encodeURIComponent(id)}/merge`, { into }); }
  updateLoreFact(orgId, id, factId, body) { return this.patch(`/orgs/${orgId}/lore/entities/${encodeURIComponent(id)}/facts/${encodeURIComponent(factId)}`, body); }
  deleteLoreFact(orgId, id, factId) { return this.delete(`/orgs/${orgId}/lore/entities/${encodeURIComponent(id)}/facts/${encodeURIComponent(factId)}`); }

  // Mailboxes — per-domain addresses (member × domain). createMailbox assigns an
  // address on a specific domain to an existing membership.
  createMailbox(orgId, { membershipId, domainId, localPart }) {
    return this.post(`/orgs/${orgId}/mailboxes`, { membership_id: membershipId, domain_id: domainId, local_part: localPart });
  }

  // Members (org-scoped; one membership per user). updateMember sets role/status
  // and per-domain access ({ all_domains } or { domain_ids: [domainKey,…] }).
  // Org agents (spec 5.5): list, update (name, status, permissions, ...), make an agt_ credential.
  listAgents(orgId) { return this.get(`/orgs/${orgId}/agents`); }
  updateAgent(orgId, agentKey, attrs) { return this.patch(`/orgs/${orgId}/agents/${agentKey}`, attrs); }
  agentCredential(orgId, agentKey) { return this.post(`/orgs/${orgId}/agents/${agentKey}/credentials`); }
  getMembers(orgId) { return this.get(`/orgs/${orgId}/members`); }
  updateMember(orgId, memberKey, attrs) { return this.patch(`/orgs/${orgId}/members/${memberKey}`, attrs); }
  removeMember(orgId, memberKey) { return this.delete(`/orgs/${orgId}/members/${memberKey}`); }
  resendInvite(orgId, memberKey) { return this.post(`/orgs/${orgId}/members/${memberKey}/resend-invite`); }
  // Team activity board: per-member action tallies + sparkline, and one member's feed.
  getMemberActivity(orgId) { return this.get(`/orgs/${orgId}/members/activity`); }
  getMemberFeed(orgId, memberKey) { return this.get(`/orgs/${orgId}/members/${memberKey}/activity`); }

  // Admin — cross-domain user management (spans every domain the admin manages)
  adminUsers() { return this.get('/admin/users'); }
  adminUser(userId) { return this.get(`/admin/users/${userId}`); }
  assignUserDomain(userId, params) { return this.post(`/admin/users/${userId}/assign`, params); }
  unassignUserDomain(userId, orgId) { return this.delete(`/admin/users/${userId}/assign?org_id=${encodeURIComponent(orgId)}`); }
  setUserStatus(userId, params) { return this.patch(`/admin/users/${userId}/status`, params); }
  // params: { scope, org_id?, data_handling, alias_handling, reroute_target_id? }
  deleteUser(userId, params = {}) {
    const qs = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v != null) qs.append(k, v);
    const query = qs.toString();
    return this.delete(`/admin/users/${userId}${query ? `?${query}` : ''}`);
  }

  // Tags
  getTags(orgId) { return this.get(`/orgs/${orgId}/tags`); }
  // { name, color?, private } — private: a label only the caller sees (anyone may make one).
  createTag(orgId, body) { return this.post(`/orgs/${orgId}/tags`, body); }
  updateTag(orgId, tagId, body) { return this.patch(`/orgs/${orgId}/tags/${tagId}`, body); }
  deleteTag(orgId, tagId) { return this.delete(`/orgs/${orgId}/tags/${tagId}`); }
  shareTag(orgId, tagId) { return this.post(`/orgs/${orgId}/tags/${tagId}/share`); }
  // { add_tag_ids, remove_tag_ids } changes only those; { tag_ids } replaces the set.
  updateConversationTags(orgId, convId, body) { return this.put(`/orgs/${orgId}/conversations/${convId}/tags`, body); }

  // Spaces (MX classification buckets)
  getSpaces(orgId) { return this.get(`/orgs/${orgId}/spaces`); }
  createSpace(orgId, params) { return this.post(`/orgs/${orgId}/spaces`, params); }
  updateSpace(orgId, spaceId, params) { return this.patch(`/orgs/${orgId}/spaces/${spaceId}`, params); }
  deleteSpace(orgId, spaceId) { return this.delete(`/orgs/${orgId}/spaces/${spaceId}`); }

  // Jev triage action labels (built-ins + org custom; writes are admin-only)
  getTriageLabels(orgId) { return this.get(`/orgs/${orgId}/triage-labels`); }
  // An organization's logo, cover image and colour, looked up server-side by domain
  // (docs/plans/lore.md §4b). Image URLs are image-proxy paths: load via fetchProxiedImage.
  getBrand(domain) { return this.get(`/brands/${encodeURIComponent(domain)}`); }
  createTriageLabel(orgId, params) { return this.post(`/orgs/${orgId}/triage-labels`, params); }
  updateTriageLabel(orgId, labelId, params) { return this.patch(`/orgs/${orgId}/triage-labels/${labelId}`, params); }
  deleteTriageLabel(orgId, labelId) { return this.delete(`/orgs/${orgId}/triage-labels/${labelId}`); }

  // Messages
  sendMessage(orgId, params) { return this.post(`/orgs/${orgId}/messages`, params); }
  // Raw MIME is a string of real headers and addresses — nothing a field-level
  // scrub can fix, so demo mode doesn't show it (same as the local-channel path).
  getMessageRaw(orgId, convId, messageId) {
    if (isDemoMode()) return Promise.resolve(DEMO_HIDDEN_SOURCE);
    return this.get(`/orgs/${orgId}/conversations/${convId}/raw/${messageId}`);
  }

  // Drafts
  getDrafts(orgId) { return this.get(`/orgs/${orgId}/drafts`); }
  createDraft(orgId, params) { return this.post(`/orgs/${orgId}/drafts`, params); }
  updateDraft(orgId, draftId, params) { return this.patch(`/orgs/${orgId}/drafts/${draftId}`, params); }
  deleteDraft(orgId, draftId) { return this.delete(`/orgs/${orgId}/drafts/${draftId}`); }

  // Notes
  createNote(orgId, convId, params) { return this.post(`/orgs/${orgId}/conversations/${convId}/notes`, params); }

  // Templates
  getTemplates(orgId) { return this.get(`/orgs/${orgId}/templates`); }

  // Search
  // `filters` are the structured search operators (from/is/in/larger/…) as built
  // by lib/searchQuery.js toApiParams(); the free text stays in `q`.
  search(orgId, query, filters = {}) {
    const params = new URLSearchParams({ q: query });
    for (const [key, value] of Object.entries(filters)) params.set(key, value);
    return this.get(`/orgs/${orgId}/search?${params}`);
  }

  // Notifications
  getNotifications() { return this.get('/notifications'); }
  markNotificationsRead(ids) { return this.post('/notifications/read', { notification_ids: ids }); }

  // A sender's picture (Gravatar, else their domain's icon) or null when there
  // is none — a 404 is the normal "draw initials" answer, not an error.
  async fetchAvatar(email) {
    const token = await this.getToken();
    if (!token && isTauri()) throw statusError('Avatar unauthenticated.', 401); // not a miss: retry after sign-in
    const headers = token ? { Authorization: `Bearer ${token}` } : {};
    const res = await fetch(`${API_BASE}/avatars?email=${encodeURIComponent(email)}`, { headers, credentials: 'include' });
    if (res.status === 404) return null;
    if (!res.ok) throw statusError(`Avatar failed (${res.status}).`, res.status);
    const blob = await res.blob();
    return blob.type.startsWith('image/') ? blob : null;
  }

  // Image proxy — fetch a remote email image server-side (privacy). Returns a
  // Blob; the bearer token rides in the header, never in the URL.
  async fetchProxiedImage(remoteUrl) {
    const token = await this.getToken();
    // Desktop must have a bearer; prod web authenticates with the HttpOnly
    // session cookie instead (credentials:'include'), like every other request.
    if (!token && isTauri()) throw statusError('Image proxy unauthenticated.', 401);

    const headers = token ? { Authorization: `Bearer ${token}` } : {};
    let res;
    try {
      res = await fetch(`${API_BASE}/image-proxy?url=${encodeURIComponent(remoteUrl)}`, { headers, credentials: 'include' });
    } catch {
      throw statusError('Image proxy unreachable.', 0); // network error reaching our own API
    }
    if (!res.ok) throw statusError(`Image proxy failed (${res.status}).`, res.status);
    // The proxy returns raw image bytes. If a 200 carries anything else (e.g. an
    // SPA index.html or an HTML error page served when the request didn't actually
    // reach the Rails endpoint), treat it as a failure so the caller surfaces the
    // "Load directly" fallback instead of swapping HTML in as a broken image.
    const blob = await res.blob();
    if (!blob.type.startsWith('image/')) {
      throw statusError(`Image proxy returned non-image (${blob.type || 'unknown'}).`, 502);
    }
    return blob;
  }

  // Meet links (docs/Calendar.md) — per-member public scheduling links.
  listMeetLinks(orgId) { return this.get(`/orgs/${orgId}/meet-links`); }
  createMeetLink(orgId, params) { return this.post(`/orgs/${orgId}/meet-links`, params); }
  revokeMeetLink(orgId, linkId) { return this.delete(`/orgs/${orgId}/meet-links/${linkId}`); }

  // Blocked time — "not available" windows that read as busy everywhere.
  listBlockedTimes(orgId, start, end) {
    return this.get(`/orgs/${orgId}/blocked-times?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}`);
  }
  createBlockedTime(orgId, params) { return this.post(`/orgs/${orgId}/blocked-times`, params); }
  deleteBlockedTime(orgId, blockId) { return this.delete(`/orgs/${orgId}/blocked-times/${blockId}`); }

  // Calendar zones (docs/Calendar.md "Zones") — user-scoped, not per org.
  listZones(start, end) {
    return this.get(`/account/zones?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}`);
  }
  createZone(params) { return this.post('/account/zones', params); }
  updateZone(zoneId, params) { return this.patch(`/account/zones/${zoneId}`, params); }
  deleteZone(zoneId, { only = false } = {}) { return this.delete(`/account/zones/${zoneId}${only ? '?scope=occurrence' : ''}`); }
  listZoneCategories() { return this.get('/account/zone-categories'); }
  dismissZone(occurrenceId, endAt) { return this.post('/account/zone-dismissals', { occurrence_id: occurrenceId, end_at: endAt }); }
  createZoneCategory(params) { return this.post('/account/zone-categories', params); }
  updateZoneCategory(categoryId, params) { return this.patch(`/account/zone-categories/${categoryId}`, params); }
  deleteZoneCategory(categoryId) { return this.delete(`/account/zone-categories/${categoryId}`); }

  // Meeting requests — invitee-only accept/decline.
  acceptMeetingRequest(orgId, requestId) { return this.post(`/orgs/${orgId}/meeting-requests/${requestId}/accept`); }
  declineMeetingRequest(orgId, requestId, reason) { return this.post(`/orgs/${orgId}/meeting-requests/${requestId}/decline`, { reason }); }

  // Conferencing connections (Meet/Teams link generation at accept time).
  listConferencing(orgId) { return this.get(`/orgs/${orgId}/conferencing`); }
  connectConferencing(orgId, provider) { return this.post(`/orgs/${orgId}/conferencing/${provider}/connect`); }
  disconnectConferencing(orgId, provider) { return this.delete(`/orgs/${orgId}/conferencing/${provider}`); }

  // Public meet-link scheduler (no auth — the token in the URL is the capability).
  getMeet(token) { return this.get(`/meet/${encodeURIComponent(token)}`); }
  getMeetAvailability(token, start, end) {
    return this.get(`/meet/${encodeURIComponent(token)}/availability?start=${encodeURIComponent(start)}&end=${encodeURIComponent(end)}`);
  }
  createMeetRequest(token, params) { return this.post(`/meet/${encodeURIComponent(token)}/requests`, params); }

  // Plans & billing (billing is org-scoped: the subscription belongs to the org)
  getPlans() { return this.get('/plans'); }
  getBilling(orgId) { return this.get(`/orgs/${orgId}/billing`); }
  subscribe(orgId, planId, opts = {}) { return this.post(`/orgs/${orgId}/billing/subscribe`, { plan_id: planId, acknowledge: opts.acknowledge || undefined }); }
  // Domains (an org owns many)
  listDomains(orgId) { return this.get(`/orgs/${orgId}/domains`); }
  addDomain(orgId, domain) { return this.post(`/orgs/${orgId}/domains`, { domain }); }
  removeDomain(orgId, domainKey) { return this.delete(`/orgs/${orgId}/domains/${domainKey}`); }
  // Per-domain DNS (a non-primary domain has its own records + verify, distinct
  // from the org-level endpoints which act on the primary domain).
  getDomainDns(orgId, domainKey) { return this.get(`/orgs/${orgId}/domains/${domainKey}/dns`); }
  verifyDomainDns(orgId, domainKey) { return this.post(`/orgs/${orgId}/domains/${domainKey}/dns/verify`); }
  // One-click: write the required records into the domain's Cloudflare zone with a
  // customer API token, then re-verify. Returns { applied, status, verified, checks }.
  configureCloudflareDns(orgId, domainKey, token) {
    return this.post(`/orgs/${orgId}/domains/${domainKey}/dns/cloudflare`, { token });
  }

  // Open tracking (docs/Open-Tracking.md). getDomainTracking → { open_tracking_enabled,
  // tracking_domain, tracking_host, default_host, verified, records, cloudflare_saas }.
  getDomainTracking(orgId, domainKey) { return this.get(`/orgs/${orgId}/domains/${domainKey}/tracking`); }
  // patch: { open_tracking_enabled?, tracking_domain? } (empty tracking_domain = inbox2 default host)
  updateDomainTracking(orgId, domainKey, patch) { return this.patch(`/orgs/${orgId}/domains/${domainKey}/tracking`, patch); }
  // → adds dns:{ ok, proxied, error } + cert status; sets verified when the CNAME (+cert) is good.
  verifyDomainTracking(orgId, domainKey) { return this.post(`/orgs/${orgId}/domains/${domainKey}/tracking/verify`); }

  // Per-CHANNEL custom tracking host (local accounts). register provisions CF-for-SaaS
  // TLS + returns { records, cname_target, cloudflare_saas }; verify-host checks DNS+cert.
  registerTrackingHost(host) { return this.post('/tracking/register', { host }); }
  verifyTrackingHost(host) { return this.post('/tracking/verify-host', { host }); }

  // Cloud-synced per-channel tracking config (authenticated — mx session or ink_).
  getChannelTracking() { return this.get('/tracking/channels'); }
  // patch: { email, open_tracking_enabled?, track_domain? }
  setChannelTracking(patch) { return this.put('/tracking/channels', patch); }

  // E2EE key provisioning (docs/E2EE.md Phase B/F). All blobs are opaque
  // ciphertext — the crypto lives client-side in lib/e2ee.js.
  getUserKey() { return this.get('/user-key'); }
  putUserKey(body) { return this.put('/user-key', body); }
  sendRecoveryEmail(blob) { return this.post('/user-key/recovery-email', { blob }); }
  getDomainE2ee(orgId, domainKey) { return this.get(`/orgs/${orgId}/domains/${domainKey}/e2ee`); }
  // patch: { e2ee_enabled?, e2ee_notification_preview? }
  setDomainE2ee(orgId, domainKey, patch) { return this.put(`/orgs/${orgId}/domains/${domainKey}/e2ee`, patch); }
  mintDomainKeys(orgId, domainKey, publicKey, grants) {
    return this.post(`/orgs/${orgId}/domains/${domainKey}/e2ee/keys`, { public_key: publicKey, grants });
  }
  grantDomainKey(orgId, domainKey, membershipId, sealedSecretKey) {
    return this.post(`/orgs/${orgId}/domains/${domainKey}/e2ee/grants`, { membership_id: membershipId, sealed_secret_key: sealedSecretKey });
  }
}

const api = new ApiClient();
export default api;
