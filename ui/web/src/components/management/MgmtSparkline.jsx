import { seriesToPath } from '../../lib/format';
import styles from './MgmtSparkline.module.css';

// Decorative fallback sparks used only while a real series hasn't loaded yet.
const SPARKS = [
  'M0,34 C14,30 22,15 36,19 C50,23 58,8 70,12 C82,15 90,28 100,16',
  'M0,30 C12,33 20,20 32,22 C46,24 56,30 68,18 C80,8 90,14 100,9',
  'M0,38 C16,34 24,26 38,28 C52,30 60,14 72,16 C84,18 92,24 100,12',
];

// Stroke-only sparkline (no gradient fill) — matches the flat line aesthetic.
export default function MgmtSparkline({ variant = 0, color = '#2f7ad6', points }) {
  // Real series → its path (null when there's no activity yet); only fall back
  // to the decorative spark when NO series was provided (e.g. still loading).
  const line = points ? seriesToPath(points) : SPARKS[variant % SPARKS.length];
  if (!line) return null; // no activity → draw nothing, not a flat baseline line
  return (
    <svg className={styles.spark} viewBox="0 0 100 44" preserveAspectRatio="none" aria-hidden="true">
      <path d={line} fill="none" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
