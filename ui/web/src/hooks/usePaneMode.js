import { useState, useEffect, useCallback } from 'react';

// Rider-style tool-window modes for the unified inbox's side panes (calendar
// rail, reading pane). Pinned = always inline; floating = pops over the
// columns when something opens it and goes away on a click elsewhere or
// Escape; hidden = collapsed to its edge strip until another mode is picked.
export const PANE_MODE = { PINNED: 'pinned', FLOATING: 'floating', HIDDEN: 'hidden' };

// Menu rows + the glyph a host uses to show the current mode on its trigger.
// (Live here, not in PaneMode.jsx, so that file only exports components.)
export const PANE_MODE_ITEMS = [
  { value: PANE_MODE.PINNED, label: 'Pinned', icon: 'macwindow' },
  { value: PANE_MODE.FLOATING, label: 'Floating', icon: 'macwindow.floating' },
  { value: PANE_MODE.HIDDEN, label: 'Hidden', icon: 'eye.slash' },
];
export const paneModeIcon = (mode) => PANE_MODE_ITEMS.find((i) => i.value === mode)?.icon;

const readMode = (key, fallback) => {
  try {
    const v = localStorage.getItem(key);
    return Object.values(PANE_MODE).includes(v) ? v : fallback;
  } catch { return fallback; }
};

// `ref` wraps everything that counts as "inside" the pane (its strip + the
// float). `ignore` is a selector for outside clicks that must not dismiss —
// the reading pane passes its conversation rows, whose own select handler
// reopens the pane (dismiss + reopen would flicker).
export default function usePaneMode(storageKey, ref, ignore) {
  const [mode, setModeState] = useState(() => readMode(storageKey, PANE_MODE.PINNED));
  const [open, setOpen] = useState(false);

  const setMode = useCallback((m) => {
    setModeState(m);
    // Picking "floating" shows the pane right away so the choice is visible.
    setOpen(m === PANE_MODE.FLOATING);
    try { localStorage.setItem(storageKey, m); } catch { /* storage unavailable */ }
  }, [storageKey]);

  const floating = mode === PANE_MODE.FLOATING;
  const shown = mode === PANE_MODE.PINNED || (floating && open);

  useEffect(() => {
    if (!(floating && open)) return undefined;
    const onPointer = (e) => {
      if (ref.current?.contains(e.target)) return;
      // Portaled menus/popovers live outside #root — using one isn't "away".
      if (!document.getElementById('root')?.contains(e.target)) return;
      if (ignore && e.target.closest?.(ignore)) return;
      setOpen(false);
    };
    const onKey = (e) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onPointer);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onPointer);
      document.removeEventListener('keydown', onKey);
    };
  }, [floating, open, ref, ignore]);

  return { mode, setMode, open, setOpen, shown, floating, strip: mode !== PANE_MODE.PINNED };
}
