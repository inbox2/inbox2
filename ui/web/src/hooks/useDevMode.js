import { useSyncExternalStore } from 'react';
import { DEV_MODE as STORAGE_KEY } from '../lib/storageKeys';

// Module-level store: ONE source of truth + ONE window key listener for the
// whole app. The previous per-hook-instance version gave every consumer its
// own useState + its own listener, so instances could diverge (the unified
// inbox's palette missing a toggle that the channel view's palette saw).
const listeners = new Set();
let current = typeof localStorage !== 'undefined' && localStorage.getItem(STORAGE_KEY) === 'true';

function toggle() {
  current = !current;
  localStorage.setItem(STORAGE_KEY, String(current));
  listeners.forEach((l) => l());
}

// Registered once at module load (guarded against dev-time HMR re-binding), so
// the backtick works on every screen — including ones that mount no consumer.
if (typeof window !== 'undefined' && !window.__inbox2DevModeKeyBound) {
  window.__inbox2DevModeKeyBound = true;
  window.addEventListener('keydown', (e) => {
    // Ignore if typing in an input
    const tag = e.target?.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA' || e.target?.contentEditable === 'true') return;
    // Match the physical key (`code`) as well as the character: on dead-key
    // layouts (US-International — common on Dutch setups) backtick reports
    // e.key === 'Dead' and the character match alone never fires.
    if (e.key === '`' || e.code === 'Backquote') {
      e.preventDefault();
      toggle();
    }
  });
}

/**
 * Global developer mode toggle.
 * Press backtick (`) anywhere to toggle — all consumers update together.
 * Persists in localStorage so it survives page reloads.
 */
export default function useDevMode() {
  return useSyncExternalStore(
    (cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    },
    () => current,
  );
}
