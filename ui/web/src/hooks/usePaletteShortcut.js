import { useEffect, useRef } from 'react';

// ⌘P / Ctrl+P — command palette (registry id `palette` in lib/shortcuts.js,
// kept scope:'doc' there: the palette's open state lives per page, so the
// shared binding is this hook rather than the message-action dispatcher).
// `onTrigger` decides what firing means (toggle vs open) — pass an inline
// arrow; it's read through a ref so the listener binds once.

/**
 * True for ⌘P / Ctrl+P with no foreign modifier held.
 * - `key.toLowerCase()` so ⇧⌘P and Caps Lock still match.
 * - `code` fallback for non-Latin layouts, where `key` is 'з'/'π'/… .
 * - Alt excluded: ⌥⌘P is free for other bindings, and on Windows Ctrl+Alt is
 *   AltGr, which types real characters we must not swallow.
 */
export function matchesPaletteKey(e) {
  if (!(e.metaKey || e.ctrlKey) || e.altKey || e.repeat) return false;
  return e.key?.toLowerCase() === 'p' || e.code === 'KeyP';
}

export default function usePaletteShortcut(onTrigger) {
  const cb = useRef(onTrigger);
  useEffect(() => { cb.current = onTrigger; });
  useEffect(() => {
    const handler = (e) => {
      if (!matchesPaletteKey(e)) return;
      e.preventDefault();
      cb.current();
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);
}
