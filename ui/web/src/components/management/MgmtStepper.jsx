import { useId } from 'react';
import styles from './MgmtStepper.module.css';

/* Management-layer −/value/+ counter. Controlled via value/onChange(nextNumber).
 * Clamps to [min, max]. Used for "how many Gmail accounts" on the waitlist form. */
export default function MgmtStepper({ label, value = 0, onChange, min = 0, max = 99, className }) {
  const id = useId();
  const set = (next) => onChange?.(Math.max(min, Math.min(max, next)));
  return (
    <div className={[styles.field, className].filter(Boolean).join(' ')}>
      {label && <span className={styles.label} id={id}>{label}</span>}
      <div className={styles.control} role="group" aria-labelledby={id}>
        <button type="button" className={styles.btn} onClick={() => set(value - 1)} disabled={value <= min} aria-label="Decrease">−</button>
        <span className={styles.value}>{value}</span>
        <button type="button" className={styles.btn} onClick={() => set(value + 1)} disabled={value >= max} aria-label="Increase">+</button>
      </div>
    </div>
  );
}
