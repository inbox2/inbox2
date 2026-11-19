import styles from './Ghosts.module.css';

/* Low-fidelity skeleton scaffolding for empty states.
   Purely decorative — aria-hidden, pointer-events: none — it mirrors the
   shape of the populated triage UI (intake rail → card stream → Eisenhower
   matrix) so the first-run experience reads as "this is where mail lands"
   rather than a blank void. Kept faint + theme-aware in Ghosts.module.css. */

// One ghost list row: avatar dot + a subject bar + a preview bar.
// Width variation is driven by :nth-child in the stylesheet (no inline styles).
function GhostRow() {
  return (
    <div className={styles.row}>
      <div className={styles.dot} />
      <div className={styles.lines}>
        <div className={`${styles.line} ${styles.lineTitle}`} />
        <div className={`${styles.line} ${styles.linePreview}`} />
      </div>
    </div>
  );
}

// One ghost intake card for the top stream (mirrors EmailCard: left priority
// stripe, avatar + name header, subject + time).
function GhostRailCard() {
  return (
    <div className={styles.railCard}>
      <div className={styles.railStripe} />
      <div className={styles.railTop}>
        <div className={styles.railDot} />
        <div className={styles.railName}>
          <div className={`${styles.line} ${styles.railNameLine}`} />
          <div className={`${styles.line} ${styles.railEmailLine}`} />
        </div>
      </div>
      <div className={`${styles.line} ${styles.railSubject}`} />
      <div className={`${styles.line} ${styles.railTime}`} />
    </div>
  );
}

// Mirrors the Eisenhower matrix: 2×2 quadrants, each with an accent header
// bar + label stub and a handful of ghost rows.
const GHOST_QUADRANTS = [
  { accent: styles.accentDanger, rows: 3 },
  { accent: styles.accentPrimary, rows: 2 },
  { accent: styles.accentTeal, rows: 2 },
  { accent: styles.accentNeutral, rows: 3 },
];

export function GhostTriageBackdrop() {
  return (
    <div className={styles.triageBackdrop} aria-hidden="true">
      {/* Intake rail header */}
      <div className={styles.railHeader}>
        <div className={`${styles.line} ${styles.railHeaderLabel}`} />
        <div className={`${styles.line} ${styles.railHeaderCount}`} />
      </div>

      {/* Horizontal card stream */}
      <div className={styles.rail}>
        {Array.from({ length: 8 }).map((_, i) => (
          <GhostRailCard key={i} />
        ))}
      </div>

      {/* 2×2 matrix */}
      <div className={styles.matrix}>
        {GHOST_QUADRANTS.map((q, i) => (
          <div key={i} className={styles.quadrant}>
            <div className={styles.qHeader}>
              <div className={`${styles.qBar} ${q.accent}`} />
              <div className={styles.qLabel} />
            </div>
            <div className={styles.qBody}>
              {Array.from({ length: q.rows }).map((_, r) => (
                <GhostRow key={r} />
              ))}
            </div>
          </div>
        ))}
      </div>

      <div className={styles.shimmer} />
    </div>
  );
}

// A stack of ghost rows for an empty account column.
export function GhostColumn({ rows = 6 }) {
  return (
    <div className={styles.ghostColumn} aria-hidden="true">
      {Array.from({ length: rows }).map((_, r) => (
        <GhostRow key={r} />
      ))}
      <div className={styles.shimmer} />
    </div>
  );
}
