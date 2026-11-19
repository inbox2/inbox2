import { forwardRef } from 'react'
import styles from './Checkbox.module.css'

const Checkbox = forwardRef(function Checkbox({ children, className, ...props }, ref) {
  const classes = [styles.label, className].filter(Boolean).join(' ')

  return (
    <label className={classes}>
      <input ref={ref} type="checkbox" className={styles.checkbox} {...props} />
      <span>{children}</span>
    </label>
  )
})

export default Checkbox
