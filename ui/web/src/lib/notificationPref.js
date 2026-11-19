// Desktop notification preferences — the alert *mode*. A small external store
// (like markReadPref/linkOpenPref) so the new-message handler can read the
// current value synchronously via getNotificationPref(), while settings stay
// reactive through useNotificationPref(). (Sound choice lives in soundPref.)
import { useSyncExternalStore, useCallback } from 'react';
import { NOTIFICATIONS_ENABLED, NOTIFICATION_MODE } from './storageKeys';
import { createExternalStore, readBool } from './prefStore';

/** Notification delivery modes. */
export const NOTIFICATION_MODES = {
  CUSTOM: 'custom', // in-app glass card stack (current bespoke UI)
  SYSTEM: 'system', // native OS notification (macOS Notification Center / Windows)
  NONE: 'none',     // no visible alert (still recorded to the activity feed)
};

const VALID_MODES = new Set(Object.values(NOTIFICATION_MODES));

/** Resolve the initial mode, migrating the legacy enabled boolean once. */
function readMode() {
  const stored = localStorage.getItem(NOTIFICATION_MODE);
  if (stored && VALID_MODES.has(stored)) return stored;
  // Migration: a user who had previously turned notifications off keeps that
  // intent as 'none'; otherwise default to the custom card UI.
  return readBool(NOTIFICATIONS_ENABLED, true) ? NOTIFICATION_MODES.CUSTOM : NOTIFICATION_MODES.NONE;
}

let _mode = readMode();

const _store = createExternalStore(() => ({
  mode: _mode,
  enabled: _mode !== NOTIFICATION_MODES.NONE,
}));
export const getNotificationPref = _store.getSnapshot;

export function setNotificationMode(value) {
  const v = VALID_MODES.has(value) ? value : NOTIFICATION_MODES.CUSTOM;
  if (v === _mode) return;
  _mode = v;
  localStorage.setItem(NOTIFICATION_MODE, v);
  _store.emit();
}

export default function useNotificationPref() {
  const { mode, enabled } = useSyncExternalStore(_store.subscribe, _store.getSnapshot);
  return {
    mode,
    enabled,
    setMode: useCallback((v) => setNotificationMode(v), []),
  };
}
