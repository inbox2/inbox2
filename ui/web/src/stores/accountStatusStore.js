import { create } from 'zustand';
import syncManager from '../lib/sync-manager';

// Live per-account connection status (connected / needs_reauth / error / …), kept
// current from the engine's `account-status` events so the reconnect indicators
// (channel tiles, chrome tabs, inbox banner) react without a reload. Seeded from
// the accounts loaded at boot; live events take precedence after that.
const useAccountStatusStore = create((set, get) => ({
  byKey: {},

  // A live status transition for one account (authoritative once it fires).
  setStatus(key, status) {
    if (!key || !status) return;
    if (get().byKey[key] === status) return;
    set({ byKey: { ...get().byKey, [key]: status } });
  },

  // Bootstrap from a loaded account list. Only fills keys we don't already track,
  // so a live transition is never clobbered by a stale seed.
  seed(accounts) {
    const cur = get().byKey;
    let next = null;
    for (const a of accounts || []) {
      if (a?.key && a.status && cur[a.key] === undefined) {
        next = next || { ...cur };
        next[a.key] = a.status;
      }
    }
    if (next) set({ byKey: next });
  },
}));

// Subscribe at module load, NOT from a component. `seed` refuses to overwrite a
// key it already tracks, so a status that transitions while no subscriber is
// mounted is lost for good: reconnecting an account from Settings (where the
// ChromeBar and its hook aren't mounted) left the channel tile showing the red
// "needs reconnect" ring until the next 60s poll happened to emit again.
syncManager.on('account-status', (p) => {
  if (p?.accountKey && p.status) useAccountStatusStore.getState().setStatus(p.accountKey, p.status);
});

// A status that means the account can't sync until the user re-authenticates —
// the trigger for the red "needs reconnection" indicators and the "Sign-in
// expired" banner. Only `needs_reauth` qualifies: that's a dead credential the
// user must fix. A transient `error` (network blip, provider 5xx, a brief rate
// limit) is NOT an expired sign-in — the 60s poll auto-recovers it — so it must
// not raise the reconnect UI, which would falsely tell the user to re-auth.
export function needsReconnect(status) {
  return status === 'needs_reauth';
}

export default useAccountStatusStore;
