import { forwardRef } from 'react'
import styles from './Button.module.css'

const Button = forwardRef(function Button({ variant, className, children, ...props }, ref) {
  const classes = [
    styles.button,
    variant === 'secondary' ? styles.secondary
      : variant === 'ghost' ? styles.ghost
      : variant === 'danger' ? styles.danger
      : variant === 'danger-outline' ? styles.dangerOutline
      : variant === 'link' ? styles.link
      : variant === 'danger-link' ? styles.dangerLink
      : '',
    className || '',
  ].filter(Boolean).join(' ')

  return (
    <button ref={ref} className={classes} {...props}>
      {children}
    </button>
  )
})

export default Button
