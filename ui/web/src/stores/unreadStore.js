import { create } from 'zustand';

export function formatBadge(count) {
  return count > 99 ? '99+' : count;
}

// The unread badge, per channel + the summed total (ChromeBar tabs, the account
// switcher, the desktop dock badge).
//
// Two writers, deliberately:
//   setChannelCount — the truth, from useChannelUnreadCounts (a SQL COUNT for
//     local channels, the API's count endpoint for MX). The ONLY absolute writer.
//   adjust — an optimistic delta so the number moves the instant you click,
//     from conversationActions.unreadDelta. Always reconciled by the next recount.
//
// There used to be a third shape: setCounts(list), which re-derived every count
// from whatever conversation list the current screen was holding. Those lists
// are paginated (25 from the API, 50 from the local MX mirror, 200 from SQLite),
// so the badge meant something different on every screen, MX tabs silently
// capped at 25, and the count changed as you navigated. Count, don't re-derive.
const useUnreadStore = create((set, get) => ({
  total: 0,
  byChannel: {},
  // Bumped on every optimistic adjust. useChannelUnreadCounts samples it before
  // an async recount and drops the result if it moved — otherwise a read that
  // started before you filed a thread lands afterwards and puts the old number
  // back. See the staleness guard there.
  mutations: 0,

  // Move a channel's count by `delta` without re-deriving it.
  //
  // Every action dispatcher applies this the moment the user clicks (removals,
  // mark read/unread, restores), so the badge never waits on a provider write or
  // a refetch. Clamped at zero; any drift (acting on a thread already read
  // elsewhere) is corrected by the next setChannelCount.
  adjust(key, delta) {
    if (!key || !delta) return;
    const prev = get();
    const current = prev.byChannel[key] || 0;
    const next = Math.max(0, current + delta);
    // Still count the mutation when the clamp swallows it: the recount in flight
    // is just as stale either way.
    if (next === current) { set({ mutations: prev.mutations + 1 }); return; }
    const byChannel = { ...prev.byChannel, [key]: next };
    set({
      byChannel,
      total: Object.values(byChannel).reduce((a, b) => a + b, 0),
      mutations: prev.mutations + 1,
    });
  },

  // Set one channel's count to a freshly-counted truth.
  setChannelCount(key, count) {
    if (!key) return;
    const prev = get();
    if ((prev.byChannel[key] || 0) === count) return;
    const byChannel = { ...prev.byChannel, [key]: count };
    set({ byChannel, total: Object.values(byChannel).reduce((a, b) => a + b, 0) });
  },

  // Drop channels that are no longer tabs, so the total counts a mailbox once.
  // (A removed account, or a stale key left by an older build.)
  pruneTo(knownKeys) {
    const known = new Set(knownKeys || []);
    const prev = get();
    const byChannel = Object.fromEntries(
      Object.entries(prev.byChannel).filter(([k]) => known.has(k))
    );
    if (Object.keys(byChannel).length === Object.keys(prev.byChannel).length) return;
    set({ byChannel, total: Object.values(byChannel).reduce((a, b) => a + b, 0) });
  },
}));

export default useUnreadStore;
