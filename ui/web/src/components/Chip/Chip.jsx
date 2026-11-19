import { forwardRef, useRef, useEffect, useImperativeHandle } from 'react'
import Icon from '../Icon'
import styles from './Chip.module.css'

/**
 * Interactive rounded pill button — the clickable cousin of <Tag> (a static
 * span). Full-radius, overlay surface, accent-bordered on hover, ellipsis at an
 * optional max width.
 *
 * Props:
 *   onClick   — click handler
 *   children  — pill label
 *   icon      — optional leading SF Symbol name (via <Icon>)
 *   maxWidth  — optional px cap; text ellipsizes past it
 *   className — extra class(es) merged onto the button
 *   ...props  — forwarded to the underlying <button>
 */
const Chip = forwardRef(function Chip(
  { onClick, children, icon, maxWidth, className, ...props },
  ref,
) {
  const innerRef = useRef(null)
  useImperativeHandle(ref, () => innerRef.current)

  useEffect(() => {
    const el = innerRef.current
    if (!el) return
    if (maxWidth != null) el.style.setProperty('--chip-max-width', `${maxWidth}px`)
    else el.style.removeProperty('--chip-max-width')
  }, [maxWidth])

  const classes = [styles.chip, className].filter(Boolean).join(' ')

  return (
    <button ref={innerRef} type="button" className={classes} onClick={onClick} {...props}>
      {icon && <Icon name={icon} size={12} className={styles.icon} />}
      <span className={styles.label}>{children}</span>
    </button>
  )
})

export default Chip
