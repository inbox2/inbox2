import styles from './Switch.module.css';

/**
 * Accessible on/off toggle. The real control is a visually-hidden checkbox
 * (keyboard-operable, role="switch"); the track/thumb are styled siblings that
 * reflect its state.
 */
export default function Switch({ id, label, description, checked, onChange, disabled, ariaLabel }) {
  const hasText = label != null || description != null;
  return (
    <label className={hasText ? styles.row : styles.bare} htmlFor={id}>
      {hasText && (
        <span className={styles.text}>
          {label != null && <span className={styles.label}>{label}</span>}
          {description != null && <span className={styles.description}>{description}</span>}
        </span>
      )}
      <input
        id={id}
        type="checkbox"
        role="switch"
        className={styles.input}
        checked={checked}
        disabled={disabled}
        aria-label={ariaLabel}
        onChange={(e) => onChange(e.target.checked)}
      />
      <span className={styles.track} aria-hidden="true">
        <span className={styles.thumb} />
      </span>
    </label>
  );
}
