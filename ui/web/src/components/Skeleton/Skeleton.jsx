import styles from './Skeleton.module.css'

const PARTS = {
  row: <><span className={styles.icon} /><span className={`${styles.bar} ${styles.name}`} /><span className={styles.bar} /><span className={styles.bar} /><span className={styles.bar} /><span className={`${styles.bar} ${styles.size}`} /></>,
  tile: <><span className={styles.icon} /><span className={`${styles.bar} ${styles.name}`} /><span className={`${styles.bar} ${styles.small}`} /></>,
  text: <span className={styles.bar} />,
}

/**
 * Loading placeholder shaped like the content (spec F1: no full-area spinners).
 * Decorative: the caller marks its region aria-busy. Pair with useDelayedFlag(loading, 150)
 * so fast loads show nothing.
 *
 *   variant    'row' (list rows) | 'tile' (grid tiles) | 'text' (lines)
 *   count      how many items
 *   className  lets a view apply its own grid so the skeleton matches the real layout
 */
export default function Skeleton({ variant = 'row', count = 6, className }) {
  return (
    <div className={[styles.skeleton, styles[variant], className].filter(Boolean).join(' ')} aria-hidden="true">
      {Array.from({ length: count }, (_, i) => <div key={i} className={styles.item}>{PARTS[variant]}</div>)}
    </div>
  )
}
