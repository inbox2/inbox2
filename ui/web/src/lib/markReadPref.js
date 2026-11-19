// Mark-as-read preference — mirrors Outlook's "Message handling → Mark as read"
// mechanism. A small external store (like useTheme) so plain event handlers can
// read the current value synchronously via getMarkReadPref(), while components
// stay reactive through useMarkReadPref().
import { useSyncExternalStore, useCallback } from 'react';
import { MARK_READ_MODE, MARK_READ_DELAY } from './storageKeys';
import { createExternalStore } from './prefStore';

// The four Outlook modes. Values are stable strings — never hardcode them.
export const MARK_READ_MODES = {
  IMMEDIATE: 'immediate',          // mark read as soon as the item is selected
  DELAY: 'delay',                  // mark read after it's been displayed N seconds
  SELECTION_CHANGE: 'selection-change', // mark read when selection moves off it
  NEVER: 'never',                  // never auto-mark; manual only
};

const VALID_MODES = new Set(Object.values(MARK_READ_MODES));

// A short dwell (Outlook-style) — keyboard nav touches many messages, so a
// delay avoids marking them read unintentionally (unlike the mobile apps, where
// opening a message is a deliberate tap → immediate). 2.5s reads as responsive
// while still tolerating a quick skim-past.
export const DEFAULT_MARK_READ_MODE = MARK_READ_MODES.DELAY;
export const DEFAULT_MARK_READ_DELAY = 2.5;

function readMode() {
  const v = localStorage.getItem(MARK_READ_MODE);
  return v && VALID_MODES.has(v) ? v : DEFAULT_MARK_READ_MODE;
}

function readDelay() {
  const n = Number(localStorage.getItem(MARK_READ_DELAY));
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_MARK_READ_DELAY;
}

let _mode = readMode();
let _delay = readDelay();

const _store = createExternalStore(() => ({ mode: _mode, delaySeconds: _delay }));
export const getMarkReadPref = _store.getSnapshot;

export function setMarkReadMode(mode) {
  if (!VALID_MODES.has(mode) || mode === _mode) return;
  _mode = mode;
  localStorage.setItem(MARK_READ_MODE, mode);
  _store.emit();
}

export function setMarkReadDelay(seconds) {
  const n = Number(seconds);
  if (!Number.isFinite(n) || n <= 0 || n === _delay) return;
  _delay = n;
  localStorage.setItem(MARK_READ_DELAY, String(n));
  _store.emit();
}

export default function useMarkReadPref() {
  const { mode, delaySeconds } = useSyncExternalStore(_store.subscribe, _store.getSnapshot);
  const setMode = useCallback((m) => setMarkReadMode(m), []);
  const setDelaySeconds = useCallback((s) => setMarkReadDelay(s), []);
  return { mode, delaySeconds, setMode, setDelaySeconds };
}
