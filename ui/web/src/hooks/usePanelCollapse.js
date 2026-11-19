import { useState, useCallback } from 'react';
import { COLLAPSED_PANELS } from '../lib/storageKeys';

// Reads the persisted { panelKey: collapsed } map once and caches it so each
// ContextGroup doesn't re-parse localStorage on mount.
function readMap() {
  try {
    return JSON.parse(localStorage.getItem(COLLAPSED_PANELS)) || {};
  } catch {
    return {};
  }
}

let cache = readMap();

// Per-panel collapse state for the context sidebar, persisted to localStorage so
// it survives switching conversations, channels, and sessions. Keyed by a stable
// `key` (the panel title, unless the title is dynamic). Returns [collapsed, toggle].
export default function usePanelCollapse(key) {
  const [collapsed, setCollapsed] = useState(() => !!cache[key]);

  const toggle = useCallback(() => {
    setCollapsed((prev) => {
      const next = !prev;
      cache = { ...cache, [key]: next };
      try {
        localStorage.setItem(COLLAPSED_PANELS, JSON.stringify(cache));
      } catch {
        // ignore quota / private-mode failures
      }
      return next;
    });
  }, [key]);

  return [collapsed, toggle];
}
