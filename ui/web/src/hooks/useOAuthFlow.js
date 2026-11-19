import { useState, useEffect } from 'react';
import { isTauri } from '../lib/tauri';
import useDevMode from './useDevMode';
import { PROVIDER } from '../lib/providerTypes';
import log from '../lib/log';

const OAUTH_CONFIG = {
  [PROVIDER.GMAIL]: {
    tauriCommand: 'start_gmail_oauth',
    oauthModule: () => import('../lib/gmail-oauth.js'),
    eventName: 'gmail-oauth-callback',
    buildAccount: (profile, tokens) => ({
      display_name: profile.emailAddress.split('@')[0],
      email_address: profile.emailAddress,
      provider_type: PROVIDER.GMAIL,
      auth_method: 'oauth2',
      username: profile.emailAddress,
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
    }),
    getEmail: (profile) => profile.emailAddress,
  },
  [PROVIDER.MICROSOFT]: {
    tauriCommand: 'start_microsoft_oauth',
    oauthModule: () => import('../lib/microsoft-oauth.js'),
    eventName: 'microsoft-oauth-callback',
    buildAccount: (profile, tokens) => {
      const email = profile.mail || profile.userPrincipalName;
      return {
        display_name: profile.displayName || email.split('@')[0],
        email_address: email,
        provider_type: PROVIDER.MICROSOFT,
        auth_method: 'oauth2',
        username: email,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
      };
    },
    getEmail: (profile) => profile.mail || profile.userPrincipalName,
  },
};

export default function useOAuthFlow({ step, setStep, onConnected, onClose, cloudBackup }) {
  const [oauthState, setOauthState] = useState(null);
  const [oauthRedirectUri, setOauthRedirectUri] = useState(null);
  // Reconnect: the account being re-authenticated. Sent as login_hint (the
  // provider preselects it in the consent screen) and enforced after the
  // exchange — signing in as a different account would add a NEW channel while
  // the expired one stayed broken.
  const [expectedEmail, setExpectedEmail] = useState(null);
  const [error, setError] = useState(null);
  // Global dev mode (toggled anywhere with the backtick key). When on, the auth
  // URL is NOT auto-opened in the default browser — it's surfaced in a textfield
  // so it can be pasted into a different browser. The loopback callback still
  // hooks back regardless of which browser completes the flow.
  const devMode = useDevMode();
  const [authUrl, setAuthUrl] = useState(null);

  const openAuthUrl = async () => {
    if (!authUrl) return;
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('plugin:opener|open_url', { url: authUrl });
  };

  const startOAuth = async (providerType, { loginHint } = {}) => {
    const config = OAUTH_CONFIG[providerType];
    if (!config) return;

    setError(null);
    setExpectedEmail(loginHint || null);
    try {
      const { invoke } = await import('@tauri-apps/api/core');
      const { state: csrfState, redirect_uri: redirectUri } = await invoke(config.tauriCommand);
      const oauthLib = await config.oauthModule();
      const { auth_url: authUrl } = await oauthLib.getAuthUrl(csrfState, redirectUri, loginHint);
      setAuthUrl(authUrl);
      // In dev mode, let the user copy the URL into a browser of their choice
      // instead of auto-opening the OS default browser.
      if (!devMode) {
        await invoke('plugin:opener|open_url', { url: authUrl });
      }
      setOauthState(csrfState);
      setOauthRedirectUri(redirectUri);
      setStep('oauth-waiting');
    } catch (err) {
      setError(err.message || `Couldn't start ${providerType} sign-in`);
    }
  };

  // Listen for OAuth callbacks
  useEffect(() => {
    if (!isTauri() || step !== 'oauth-waiting') return;
    const unlisteners = [];

    (async () => {
      const { listen } = await import('@tauri-apps/api/event');
      const { invoke } = await import('@tauri-apps/api/core');

      for (const [providerType, config] of Object.entries(OAUTH_CONFIG)) {
        const unlisten = await listen(config.eventName, async (event) => {
          try {
            const { code, state } = event.payload || {};
            if (!code) {
              setError("Sign-in didn't finish. Try again.");
              setStep('select');
              return;
            }
            if (oauthState && state !== oauthState) {
              setError("Sign-in didn't match. Try again.");
              setStep('select');
              return;
            }

            setStep('oauth-exchanging');

            const oauthLib = await config.oauthModule();
            const tokens = await oauthLib.exchangeCode(code, oauthRedirectUri);

            // Log granted scopes for diagnostics
            if (tokens.scope) {
              log.info('OAuth', `Granted scopes: ${tokens.scope}`);
            }
            try {
              const tokenInfo = await fetch(`https://oauth2.googleapis.com/tokeninfo?access_token=${tokens.access_token}`);
              if (tokenInfo.ok) {
                const info = await tokenInfo.json();
                log.info('OAuth', `Token scopes: ${info.scope}`);
              }
            } catch { /* diagnostic only */ }

            const profile = await oauthLib.getProfile(tokens.access_token);
            const email = config.getEmail(profile);

            // Reconnect: refuse a different account than the expired one —
            // adding it would create a new channel and leave the broken one
            // still flagged needs_reauth.
            if (expectedEmail && email?.toLowerCase() !== expectedEmail.toLowerCase()) {
              setError(`You signed in as ${email}. Try again and pick ${expectedEmail}.`);
              setStep('select');
              return;
            }

            const result = await invoke('add_external_account', {
              // cloud_backup mirrors this account's credentials to the
              // zero-knowledge vault (docs/E2EE.md) when the user opted in.
              request: { ...config.buildAccount(profile, tokens), cloud_backup: cloudBackup },
            });

            onConnected?.(providerType, result, tokens, email);
            onClose?.();
          } catch (err) {
            setError(err.message || `Couldn't connect ${providerType}`);
            setStep('select');
          }
        });
        unlisteners.push(unlisten);
      }
    })();

    return () => unlisteners.forEach(fn => fn?.());
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step, oauthState, oauthRedirectUri, expectedEmail, cloudBackup]);

  const resetOAuth = () => {
    setOauthState(null);
    setOauthRedirectUri(null);
    setExpectedEmail(null);
    setAuthUrl(null);
    setError(null);
  };

  return { startOAuth, oauthState, oauthRedirectUri, oauthError: error, setOauthError: setError, resetOAuth, devMode, authUrl, openAuthUrl };
}
