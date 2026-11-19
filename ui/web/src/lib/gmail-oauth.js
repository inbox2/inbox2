// Gmail OAuth 2.0 helpers.
// Shared authorize/exchange/refresh come from createOAuthProvider; only the
// Gmail-specific profile lookup lives here. Token operations proxy through the
// Rails API so the Google client_id / client_secret never appear in client code.

import { createOAuthProvider } from './oauthProvider';

const GMAIL_API = 'https://gmail.googleapis.com/gmail/v1';

export const { getAuthUrl, exchangeCode, refreshAccessToken } = createOAuthProvider('google');

/**
 * Fetch the authenticated user's Gmail profile.
 * @param {string} accessToken
 * @returns {Promise<{emailAddress: string, messagesTotal: number, threadsTotal: number, historyId: string}>}
 */
export async function getProfile(accessToken) {
  // Primary: Gmail API profile (requires gmail.modify scope)
  const res = await fetch(`${GMAIL_API}/users/me/profile`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (res.ok) return res.json();

  // Fallback: userinfo endpoint (requires email+profile scopes)
  const fallback = await fetch('https://www.googleapis.com/oauth2/v3/userinfo', {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (fallback.ok) {
    const info = await fallback.json();
    if (info.email) return { emailAddress: info.email };
  }

  // Last resort: tokeninfo endpoint (always has email for Gmail tokens)
  const tokenInfo = await fetch(`https://oauth2.googleapis.com/tokeninfo?access_token=${accessToken}`);
  if (tokenInfo.ok) {
    const info = await tokenInfo.json();
    if (info.email) return { emailAddress: info.email };
  }

  throw new Error(`Profile fetch failed: ${res.status}`);
}
