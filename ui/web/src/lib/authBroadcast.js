// Tells the app's other tabs and windows (same origin) at once when this one
// signs out or signs in, so they react now instead of on their next request's
// 401. The message carries only what happened and whose user id it concerns:
// never a token or account data. BroadcastChannel only: every browser and
// webview the app runs in has it (the Disk engine already relies on it).
const CHANNEL = 'inbox2-auth'

export const AUTH_SIGNED_OUT = 'signed_out'
export const AUTH_SIGNED_IN = 'signed_in'
const KINDS = new Set([AUTH_SIGNED_OUT, AUTH_SIGNED_IN])

let channel
function bc() {
  if (channel === undefined) channel = typeof BroadcastChannel === 'function' ? new BroadcastChannel(CHANNEL) : null
  return channel
}

/** Tell the other tabs. kind: AUTH_SIGNED_OUT | AUTH_SIGNED_IN; userId: the account it concerns. */
export function announceAuth(kind, userId) {
  if (!KINDS.has(kind)) return
  try { bc()?.postMessage({ kind, userId: userId ?? null }) } catch { /* closed channel: nothing to tell */ }
}

/** Listen to the other tabs. fn({ kind, userId }); returns an unsubscribe. */
export function onAuthBroadcast(fn) {
  const c = bc()
  if (!c) return () => {}
  const handler = ({ data }) => {
    if (data && KINDS.has(data.kind)) fn({ kind: data.kind, userId: data.userId ?? null })
  }
  c.addEventListener('message', handler)
  return () => c.removeEventListener('message', handler)
}

/**
 * What a tab does with another tab's message.
 * tab: { userId (this tab's account, null when nobody is signed in), signedOut (the screen is up) }
 * Returns 'sign-out' (show the signed-out screen), 'resume' (the same account
 * signed in again: drop the screen), 'reload' (another account is now signed
 * in: load its home, never show the previous account's data) or 'ignore'.
 */
export function reactionTo(tab, msg) {
  if (!tab.userId) return 'ignore' // a signed-out tab (login page, public link viewer) has nothing to protect
  if (msg.kind === AUTH_SIGNED_OUT) {
    if (tab.signedOut) return 'ignore'
    return msg.userId == null || msg.userId === tab.userId ? 'sign-out' : 'ignore'
  }
  if (msg.kind === AUTH_SIGNED_IN) {
    if (msg.userId === tab.userId) return tab.signedOut ? 'resume' : 'ignore'
    return 'reload'
  }
  return 'ignore'
}
