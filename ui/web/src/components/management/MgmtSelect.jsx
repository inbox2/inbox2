import { useId } from 'react';
import styles from './MgmtSelect.module.css';

/* The ONE styled <select> — dark inset control, custom chevron, blue focus
 * ring. Native selects render with browser chrome and stick out against the
 * dark UI; every dropdown in the app goes through this component.
 *
 * Options come from `options` (array of { value, label } or plain strings) or
 * from <option> children when option-level control is needed (disabled
 * entries, conditional options, optgroups). `placeholder` renders a disabled
 * leading option.
 *
 * Variants (default renders the labelled management field: mono label, hint):
 *   bare    — control only, no label/hint wrapper, for rows that render their
 *             own label. `className` lands on the control wrap, so site layout
 *             classes (flex-basis, widths) keep working. Width is natural in
 *             row contexts, full in block contexts — like a raw <select>.
 *   compact — 38px control matching the app's standard text-input height for
 *             inline/row usage.
 * Outside the `management` token scope the --m-* tokens fall back to the main
 * app's theme tokens, so the control follows whichever theme it sits in. */
export default function MgmtSelect({
  label, hint, options = [], placeholder, className, bare = false, compact = false, children,
  ...selectProps
}) {
  const id = useId();
  const items = options.map((o) => (typeof o === 'string' ? { value: o, label: o } : o));
  const control = (
    <div className={[styles.wrap, compact && styles.compact, bare && className].filter(Boolean).join(' ')}>
      <select id={bare ? undefined : id} className={styles.select} {...selectProps}>
        {placeholder && <option value="" disabled>{placeholder}</option>}
        {children || items.map((o) => (
          <option key={o.value} value={o.value}>{o.label}</option>
        ))}
      </select>
      <span className={styles.chevron} aria-hidden="true">▾</span>
    </div>
  );
  if (bare) return control;
  return (
    <label className={[styles.field, className].filter(Boolean).join(' ')} htmlFor={id}>
      {label && <span className={styles.label}>{label}</span>}
      {control}
      {hint && <span className={styles.hint}>{hint}</span>}
    </label>
  );
}
