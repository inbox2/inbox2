// Shared machinery for the small localStorage-backed preference stores in this
// folder (cloudPush/dropBlock/imageProxy/markRead/notification/sound). Each of
// those used to hand-roll the same useSyncExternalStore plumbing — a listener
// set, a cached snapshot object (referential stability is what stops
// useSyncExternalStore from looping), an emit(), and a subscribe(). This module
// factors that out so each pref only declares its own state, setters, and hook.
import { useSyncExternalStore, useCallback } from 'react';

// Read a boolean localStorage flag, treating an absent key as `fallback`.
export function readBool(key, fallback) {
  const v = localStorage.getItem(key);
  return v === null ? fallback : v === 'true';
}

// A minimal external store: `computeSnapshot` is re-run on every emit to produce
// a fresh, referentially-stable snapshot object for useSyncExternalStore.
export function createExternalStore(computeSnapshot) {
  const listeners = new Set();
  let snapshot = computeSnapshot();

  function emit() {
    snapshot = computeSnapshot();
    for (const fn of listeners) fn();
  }
  function getSnapshot() {
    return snapshot;
  }
  function subscribe(cb) {
    listeners.add(cb);
    return () => listeners.delete(cb);
  }
  return { getSnapshot, subscribe, emit };
}

// A complete store around a single boolean localStorage preference. Returns the
// synchronous getter (`{ enabled }` snapshot), the setter, and a React hook —
// the exact shape cloudPush/dropBlock/imageProxy each re-implemented.
export function createBoolPref(storageKey, { defaultValue = true } = {}) {
  let enabled = readBool(storageKey, defaultValue);
  const store = createExternalStore(() => ({ enabled }));

  function setEnabled(value) {
    const v = !!value;
    if (v === enabled) return;
    enabled = v;
    localStorage.setItem(storageKey, String(v));
    store.emit();
  }

  function usePref() {
    const { enabled: on } = useSyncExternalStore(store.subscribe, store.getSnapshot);
    return { enabled: on, setEnabled: useCallback((v) => setEnabled(v), []) };
  }

  return { getPref: store.getSnapshot, setEnabled, usePref };
}
