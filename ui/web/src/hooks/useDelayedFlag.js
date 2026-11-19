import { useState, useEffect } from 'react';

/**
 * Returns true only after `active` has stayed true continuously for `delayMs`.
 * The moment `active` goes false it resets to false immediately.
 *
 * Used to avoid flashing transient UI during brief loading/navigation gaps —
 * e.g. the empty-state game, which should appear only when the reading pane is
 * genuinely idle, not for the one frame between a tab switch / message click and
 * the conversation detail loading.
 */
export default function useDelayedFlag(active, delayMs = 200) {
  const [on, setOn] = useState(false);
  useEffect(() => {
    if (!active) return undefined;
    const t = setTimeout(() => setOn(true), delayMs);
    // Reset on cleanup (when `active` flips false or deps change) — avoids
    // calling setState synchronously in the effect body.
    return () => { clearTimeout(t); setOn(false); };
  }, [active, delayMs]);
  return active ? on : false;
}
