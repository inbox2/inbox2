import { useEffect } from 'react';

// Invoke `onDismiss` when the user clicks/taps outside `ref` or presses Escape,
// while `enabled`. Replaces the hand-rolled
// `document.addEventListener('mousedown'…) + keydown('Escape')` blocks that used
// to be scattered across dropdown menus and popovers (an ESLint rule now keeps
// them out). For full popovers prefer the Popover catalog component; this is
// the minimal primitive for in-place menus.
//
// `ignore`: extra places a press does NOT count as outside — selectors or refs
// — for content that portals out of `ref` (a hover card rendered on <body>).
export default function useDismiss(ref, onDismiss, enabled = true, { ignore = [] } = {}) {
  // Stable identity for the ignore list so callers can pass a literal array.
  const ignoreKey = ignore.map((i) => (typeof i === 'string' ? i : 'ref')).join('|');

  useEffect(() => {
    if (!enabled) return undefined;

    const inside = (el, target) => el && (el.contains?.(target) || el.current?.contains?.(target));
    const onPointer = (e) => {
      const el = ref.current;
      if (!el || el.contains(e.target)) return;
      for (const i of ignore) {
        if (typeof i === 'string' ? e.target.closest?.(i) : inside(i, e.target)) return;
      }
      onDismiss(e);
    };
    const onKey = (e) => {
      if (e.key === 'Escape') onDismiss(e);
    };

    document.addEventListener('mousedown', onPointer);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onPointer);
      document.removeEventListener('keydown', onKey);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- ignoreKey stands in for the array
  }, [ref, onDismiss, enabled, ignoreKey]);
}
