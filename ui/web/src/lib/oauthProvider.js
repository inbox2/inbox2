// Shared OAuth 2.0 token plumbing for the external mail providers.
//
// The Gmail and Microsoft flows are identical apart from the provider path
// segment (`google` vs `microsoft`) and the provider-specific profile lookup.
// `createOAuthProvider` factors out the common authorize/exchange/refresh
// calls; each provider module keeps only its own `getProfile`.
//
// All token operations proxy through the Rails API so the provider
// client_id / client_secret never appear in client code.

import api from './api';
import { API_ORIGIN } from './apiOrigin';

const API_BASE = `${API_ORIGIN}/api/v1`;

function authHeaders() {
  const token = api.token; // hydrated by the time OAuth runs (post-startup)
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  return headers;
}

async function postProxy(path, body, failMessage) {
  const res = await fetch(`${API_BASE}${path}`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`${failMessage}: ${err}`);
  }
  return res.json();
}

/**
 * Build the proxied OAuth helpers for a provider.
 * @param {'google'|'microsoft'} provider  API path segment under /auth
 * @returns {{ getAuthUrl: Function, exchangeCode: Function, refreshAccessToken: Function }}
 */
export function createOAuthProvider(provider) {
  const base = `/auth/${provider}`;

  return {
    /**
     * Fetch the OAuth consent URL from the API.
     * @param {string} state        CSRF token
     * @param {string} redirectUri  localhost redirect URI
     * @param {string} [loginHint]  account being re-authenticated — the provider
     *                              preselects it in the consent screen
     * @returns {Promise<{auth_url: string, state: string}>}
     */
    async getAuthUrl(state, redirectUri, loginHint) {
      const params = new URLSearchParams({ redirect_uri: redirectUri });
      if (state) params.set('state', state);
      if (loginHint) params.set('login_hint', loginHint);
      const res = await fetch(`${API_BASE}${base}/authorize?${params}`, {
        headers: authHeaders(),
      });
      if (!res.ok) {
        const err = await res.text();
        throw new Error(`Couldn't start sign-in: ${err}`);
      }
      return res.json();
    },

    /**
     * Exchange an authorization code for access + refresh tokens (via API proxy).
     * @param {string} code         Authorization code from the OAuth callback
     * @param {string} redirectUri  Must match the URI used in getAuthUrl
     * @returns {Promise<{access_token: string, refresh_token: string, expires_in: number}>}
     */
    exchangeCode(code, redirectUri) {
      return postProxy(`${base}/token`, { code, redirect_uri: redirectUri }, "Couldn't finish sign-in");
    },

    /**
     * Refresh an expired access token (via API proxy).
     * @param {string} refreshToken
     * @returns {Promise<{access_token: string, expires_in: number}>}
     */
    refreshAccessToken(refreshToken) {
      return postProxy(`${base}/refresh`, { refresh_token: refreshToken }, "Couldn't renew your sign-in");
    },
  };
}
