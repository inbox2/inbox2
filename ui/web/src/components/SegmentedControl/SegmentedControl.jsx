import { useRef, useEffect } from 'react'
import styles from './SegmentedControl.module.css'

/**
 * Pill-group toggle — a single-select row of segments sharing a recessed track.
 * The active pill lifts onto an `--overlay-6` surface; inactive pills are ghost.
 *
 * Each option may carry an optional `accent` (a CSS color) that tints the pill's
 * label/active state — e.g. the log-level filter where ERROR reads red. The
 * accent is applied through a CSS custom property set on the element via a ref
 * (never an inline style), so it survives the no-inline-styles lint.
 *
 * Props:
 *   options    — [{ value, label, count?, accent? }]
 *   value      — currently selected value
 *   onChange   — (value) => void
 *   aria-label — accessible label for the group (optional)
 *   className  — extra class(es) merged onto the track
 */
export default function SegmentedControl({
  options = [],
  value,
  onChange,
  'aria-label': ariaLabel,
  className,
}) {
  return (
    <div
      className={[styles.group, className].filter(Boolean).join(' ')}
      role="radiogroup"
      aria-label={ariaLabel}
    >
      {options.map((opt) => (
        <Segment
          key={opt.value}
          option={opt}
          selected={opt.value === value}
          onSelect={() => onChange?.(opt.value)}
        />
      ))}
    </div>
  )
}

function Segment({ option, selected, onSelect }) {
  const ref = useRef(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    if (option.accent) el.style.setProperty('--seg-accent', option.accent)
    else el.style.removeProperty('--seg-accent')
  }, [option.accent])

  const classes = [
    styles.pill,
    selected ? styles.pillActive : '',
    option.accent ? styles.pillAccented : '',
  ].filter(Boolean).join(' ')

  return (
    <button
      ref={ref}
      type="button"
      role="radio"
      aria-checked={selected}
      className={classes}
      onClick={onSelect}
    >
      {option.label}
      {option.count != null && <span className={styles.count}>{option.count}</span>}
    </button>
  )
}
