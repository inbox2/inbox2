import { useState, useEffect, useCallback } from 'react';
import { useNavigate } from 'react-router';
import useAuth from './useAuth';
import syncManager from '../lib/sync-manager';
import { isTauri } from '../lib/tauri';
import log from '../lib/log';

async function fetchAccounts() {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke('list_external_accounts');
}

// The engine owns the rate limit (at most one prompt per account per 5 minutes,
// persisted), so app restarts and the other clients share one budget.
async function claimPrompt(key) {
  const { invoke } = await import('@tauri-apps/api/core');
  return invoke('claim_reauth_prompt', { accountKey: key });
}

/**
 * Watches external accounts for dead credentials (`needs_reauth`) and surfaces
 * a reconnect prompt, at most once per account per 5 minutes (the engine holds
 * that budget, so it survives restarts). Returns:
 *   prompt    — { key, email, provider } | null
 *   dismiss   — close the prompt (quiet again until the cooldown lapses)
 *   reconnect — close + jump to Settings → Connected accounts with the
 *               reconnect flow pre-armed for this account
 */
export default function useReauthAlert() {
  const [prompt, setPrompt] = useState(null);
  const navigate = useNavigate();
  const { currentOrgSlug } = useAuth();

  const surface = useCallback(async (rows) => {
    const next = rows.find((a) => a.status === 'needs_reauth');
    if (!next) return;
    if (!(await claimPrompt(next.key))) return; // prompted for it recently
    log.info('reauth', `account needs re-auth: ${next.email_address}`);
    // One prompt at a time: keep whatever is already on screen.
    setPrompt((current) => current || {
      key: next.key, email: next.email_address, provider: next.provider_type,
    });
  }, []);

  useEffect(() => {
    if (!isTauri()) return undefined;

    // Make sure the engine→bus event bridge is up even if no inbox view has
    // mounted yet (init is idempotent).
    syncManager.init().catch(() => {});

    // Boot check: a token may have died while the app was closed.
    let cancelled = false;
    fetchAccounts()
      .then((rows) => { if (!cancelled) surface(rows); })
      .catch(() => { /* not running under Tauri / engine not up yet */ });

    // Live: the engine emits `status` (bridged as account-status) whenever an
    // account's connection status changes — including the sync failure that
    // flags needs_reauth.
    const off = syncManager.on('account-status', (p) => {
      if (p?.status !== 'needs_reauth') return;
      fetchAccounts().then(surface).catch(() => {});
    });
    return () => { cancelled = true; off(); };
  }, [surface]);

  const dismiss = useCallback(() => setPrompt(null), []);

  const reconnect = useCallback(() => {
    if (!prompt) return;
    const base = currentOrgSlug ? `/${currentOrgSlug}` : '';
    navigate(`${base}/settings?section=accounts&reconnect=${encodeURIComponent(prompt.key)}`);
    setPrompt(null);
  }, [prompt, currentOrgSlug, navigate]);

  return { prompt, dismiss, reconnect };
}
