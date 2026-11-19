import { forwardRef } from 'react'
import styles from './FormField.module.css'

/**
 * Shared form field wrapper — label + input + optional hint.
 *
 * Props:
 *   label       — field label text
 *   hint        — small helper text below the input
 *   className   — extra class on the wrapper
 *   children    — if provided, renders children instead of an <input>
 *   ...rest     — forwarded to the <input> element
 */
const FormField = forwardRef(function FormField(
  { label, hint, className, children, ...inputProps },
  ref,
) {
  const wrapperClass = [styles.field, className].filter(Boolean).join(' ')

  return (
    <div className={wrapperClass}>
      {label && <label className={styles.label}>{label}</label>}
      {children || <input ref={ref} className={styles.input} {...inputProps} />}
      {hint && <span className={styles.hint}>{hint}</span>}
    </div>
  )
})

export default FormField

export function ErrorMessage({ children, className }) {
  if (!children) return null
  const classes = [styles.error, className].filter(Boolean).join(' ')
  return <div className={classes}>{children}</div>
}
