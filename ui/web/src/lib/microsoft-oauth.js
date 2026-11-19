// Microsoft OAuth 2.0 helpers.
// Shared authorize/exchange/refresh come from createOAuthProvider; only the
// Microsoft-specific profile lookup lives here. Token operations proxy through
// the Rails API so the Microsoft client_id / client_secret never appear in
// client code.

import { createOAuthProvider } from './oauthProvider';

const GRAPH_API = 'https://graph.microsoft.com/v1.0';

export const { getAuthUrl, exchangeCode, refreshAccessToken } = createOAuthProvider('microsoft');

/**
 * Fetch the authenticated user's Microsoft profile.
 * @param {string} accessToken
 * @returns {Promise<{mail: string, displayName: string, userPrincipalName: string}>}
 */
export async function getProfile(accessToken) {
  const res = await fetch(`${GRAPH_API}/me`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) {
    throw new Error(`Profile fetch failed: ${res.status}`);
  }
  return res.json();
}
