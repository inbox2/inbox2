import { useEffect, useEffectEvent, useState } from 'react';

// Poll one Touch Strip feed. Results are cached per `key` at module level, so a
// widget that remounts (compact ↔ expanded, or moving between the three shells
// that mount the strip) paints its last data at once and only refetches when
// stale. Pauses while the window is hidden; a null key disables the feed.
// The server caches every upstream too, so the interval is about freshness,
// not load.
const cache = new Map();

export default function useStripFeed(key, fetcher, intervalMs) {
  // Tagged with its key, so a key change reads the cache instead of showing the
  // previous key's data for a frame.
  const [state, setState] = useState(null);
  const fetchNow = useEffectEvent(() => fetcher());

  useEffect(() => {
    if (!key) return undefined;
    let alive = true;
    const stale = () => Date.now() - (cache.get(key)?.at || 0) >= intervalMs;
    const tick = async () => {
      if (document.hidden) return;
      try {
        const data = await fetchNow();
        cache.set(key, { data, at: Date.now() });
        if (alive) setState({ key, data });
      } catch { /* keep the last good data; the next tick retries */ }
    };

    if (stale()) tick();
    const timer = setInterval(tick, intervalMs);
    const onVisible = () => { if (!document.hidden && stale()) tick(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      alive = false;
      clearInterval(timer);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [key, intervalMs]);

  if (!key) return null;
  return state?.key === key ? state.data : cache.get(key)?.data ?? null;
}
