import { useEffect, useRef, useCallback } from 'react';
import styles from './UnifiedCubeIcon.module.css';

// The unified inbox is a 6×5 sprite sheet (`/inbox2-rotate-sheet.png`) baked from a
// left-to-right turntable render: frame 0 has the "2" facing front (the resting
// logo), the last frame has it facing right. Selecting the Unified tab spins it
// forward; leaving it spins it back.
const COLS = 6;
const ROWS = 5;
const COUNT = COLS * ROWS;
const STEP_MS = 18;

// Current frame, persisted at module scope so it survives the tab remounting on
// navigation. Without this a remount resets the index to 0, so leaving the tab
// would have nothing to reverse from and would snap to the front pose instead of
// spinning back. There's only ever one Unified tab, so a single shared value is fine.
let lastFrame = 0;

/**
 * Animated rotating-cube logo for the Unified inbox tab. `active` drives playback:
 * spins forward when the inbox becomes selected, reverses when it is deselected.
 */
export default function UnifiedCubeIcon({ active = false, className }) {
  const ref = useRef(null);
  const idx = useRef(lastFrame); // restore the spin position across remounts
  const timer = useRef(null);

  const paint = useCallback((i) => {
    lastFrame = i;
    const el = ref.current;
    if (!el) return;
    const col = i % COLS;
    const row = Math.floor(i / COLS);
    el.style.setProperty('--bgx', `${(col / (COLS - 1)) * 100}%`);
    el.style.setProperty('--bgy', `${(row / (ROWS - 1)) * 100}%`);
  }, []);

  // Step one frame at a time toward the spun (last frame) or front (frame 0) pose.
  const animateTo = useCallback((spun) => {
    clearInterval(timer.current);
    const target = spun ? COUNT - 1 : 0;
    if (idx.current === target) { paint(idx.current); return; }
    const dir = spun ? 1 : -1;
    timer.current = setInterval(() => {
      idx.current += dir;
      paint(idx.current);
      if (idx.current === target) clearInterval(timer.current);
    }, STEP_MS);
  }, [paint]);

  // Play toward the current selection on mount AND whenever it flips. Combined
  // with the persisted `lastFrame`, this animates in both directions whether the
  // tab stays mounted or remounts on navigation.
  useEffect(() => {
    animateTo(active);
    return () => clearInterval(timer.current);
  }, [active, animateTo]);

  return (
    <span
      ref={ref}
      className={className ? `${styles.cube} ${className}` : styles.cube}
      aria-hidden="true"
    />
  );
}
