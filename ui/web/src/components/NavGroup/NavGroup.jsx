import { useRef, useEffect } from 'react'
import Icon from '../Icon'
import styles from './NavGroup.module.css'

export function NavItem({ icon, label, subtitle, active, badge, color, onClick }) {
  const dotRef = useRef(null)
  const colorIconRef = useRef(null)
  useEffect(() => {
    if (dotRef.current && color) {
      dotRef.current.style.setProperty('--dot-color', color)
    }
    if (colorIconRef.current && color) {
      colorIconRef.current.style.setProperty('--icon-color', color)
    }
  }, [color])

  let indicator
  if (color && icon) {
    indicator = <span ref={colorIconRef} className={styles.coloredIcon}><Icon name={icon} size={15} /></span>
  } else if (color) {
    indicator = <span ref={dotRef} className={styles.dot} />
  } else {
    indicator = <Icon name={icon} size={17} className={styles.icon} />
  }

  return (
    <div
      className={`${styles.item} ${active ? styles.itemActive : ''}`}
      role="button"
      tabIndex={0}
      onClick={onClick}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick?.(e); } }}
    >
      {indicator}
      <span className={styles.label}>{label}</span>
      {subtitle && <span className={styles.itemSubtitle}>{subtitle}</span>}
      {badge && <span className={styles.badge}>{badge}</span>}
    </div>
  )
}

export default function NavGroup({ icon, title, action, children }) {
  return (
    <div className={styles.group}>
      <div className={`${styles.header} ${action ? styles.headerHasAction : ''}`}>
        <Icon name={icon} size={13} className={styles.headerIcon} />
        {title}
        {action && <span className={styles.headerAction}>{action}</span>}
      </div>
      {children}
    </div>
  )
}
