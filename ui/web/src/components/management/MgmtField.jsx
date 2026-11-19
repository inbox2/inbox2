import { useId } from 'react';
import styles from './MgmtField.module.css';

/* Management-layer labelled input. Forwards any input props (type, value,
 * onChange, placeholder, required, autoComplete, …). */
export default function MgmtField({ label, hint, className, ...inputProps }) {
  const id = useId();
  return (
    <label className={[styles.field, className].filter(Boolean).join(' ')} htmlFor={id}>
      {label && <span className={styles.label}>{label}</span>}
      <input id={id} className={styles.input} {...inputProps} />
      {hint && <span className={styles.hint}>{hint}</span>}
    </label>
  );
}
