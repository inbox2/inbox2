import { isTauri } from '../lib/tauri';

/**
 * Instagram-Login OAuth flow (BYOK). Mirrors useOAuthFlow's shape: a single
 * `startInstagramOAuth` kicks off the desktop Tauri round-trip — open the
 * Instagram authorize page, capture the code via the fixed-port loopback
 * (`instagram-oauth-callback`), then exchange + create the account on-device.
 *
 * Behaviorally identical to the previous inline `handleInstagramConnect`: it
 * stays "submitting" until the browser round-trip completes (or errors), and the
 * caller drives UI via the injected callbacks.
 *
 * Params (all callbacks owned by the caller so state flow is unchanged):
 *   onError      — (message) => void; called with a string error message
 *   onSubmitting — (bool) => void; toggles the submitting flag
 *   onConnected  — () => void; called after the account is created + sync started
 */
export default function useInstagramOAuth({ onError, onSubmitting, onConnected }) {
  // metaForm carries instagram_app_id / instagram_app_secret / display_name.
  const startInstagramOAuth = async (metaForm) => {
    if (!isTauri()) { onError('Connect Instagram from the desktop app'); return }
    if (!metaForm.instagram_app_id || !metaForm.instagram_app_secret) return
    onError(null); onSubmitting(true)
    try {
      const { invoke } = await import('@tauri-apps/api/core')
      const { listen } = await import('@tauri-apps/api/event')
      const start = await invoke('start_instagram_oauth', { appId: metaForm.instagram_app_id })
      const unlisten = await listen('instagram-oauth-callback', async (ev) => {
        if (ev.payload?.state && ev.payload.state !== start.state) return
        await unlisten()
        try {
          const account = await invoke('complete_instagram_oauth', {
            appId: metaForm.instagram_app_id,
            appSecret: metaForm.instagram_app_secret,
            code: ev.payload.code,
            redirectUri: start.redirect_uri,
            displayName: metaForm.display_name || null,
          })
          await invoke('start_sync', { accountKey: account.key }).catch(() => {})
          onConnected()
        } catch (err) {
          onError(typeof err === 'string' ? err : (err?.message || "Couldn't connect Instagram"))
          onSubmitting(false)
        }
      })
      await invoke('plugin:opener|open_url', { url: start.authorize_url })
    } catch (e) {
      onError(typeof e === 'string' ? e : (e?.message || "Couldn't connect Instagram"))
      onSubmitting(false)
    }
  }

  return { startInstagramOAuth }
}
