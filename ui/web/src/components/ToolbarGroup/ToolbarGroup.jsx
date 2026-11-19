import styles from './ToolbarGroup.module.css'
import Icon from '../Icon'
import Tooltip from '../Tooltip'

export function ToolbarButton({ icon, children, onClick, variant, color, disabled, className: extraClass, iconClassName, title }) {
  const colorClass = color ? styles[`color${color[0].toUpperCase()}${color.slice(1)}`] : ''
  const baseClass = variant === 'chrome' ? styles.chrome : styles.button
  const variantClass = variant && variant !== 'chrome' && styles[variant] ? styles[variant] : ''
  const classes = [baseClass, variantClass, colorClass, extraClass].filter(Boolean).join(' ')

  const btn = (
    <button type="button" className={classes} onClick={onClick} disabled={disabled}>
      {icon && <Icon name={icon} size={14} className={iconClassName} />}
      {children}
    </button>
  )

  if (title) {
    return <Tooltip content={title}>{btn}</Tooltip>
  }

  return btn
}

export function ToolbarDivider() {
  return <span className={styles.divider} role="separator" />
}

export default function ToolbarGroup({ children }) {
  return (
    <div className={styles.group}>
      {children}
    </div>
  )
}
