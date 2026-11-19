import Icon from '../Icon'
import usePanelCollapse from '../../hooks/usePanelCollapse'
import styles from './ContextPanel.module.css'

export function ContextGroup({ icon, title, badge, children, collapseKey }) {
  const [collapsed, toggle] = usePanelCollapse(collapseKey || title)
  return (
    <div className={styles.group}>
      <button
        type="button"
        className={styles.header}
        onClick={toggle}
        aria-expanded={!collapsed}
      >
        <Icon name={icon} size={13} className={styles.headerIcon} />
        {title}
        {badge && <span className={styles.headerBadge}>{badge}</span>}
        <Icon
          name="chevron.right"
          size={10}
          className={`${styles.headerChevron} ${collapsed ? '' : styles.headerChevronOpen}`}
        />
      </button>
      {!collapsed && (
        <div className={styles.body}>
          {children}
        </div>
      )}
    </div>
  )
}

export function ContextField({ label, children, mono }) {
  return (
    <div className={styles.field}>
      <span className={styles.label}>{label}</span>
      <span className={mono ? styles.valueMono : styles.value}>{children}</span>
    </div>
  )
}

export function ContextRow({ children }) {
  return <div className={styles.row}>{children}</div>
}

export function CollaboratorRow({ avatar, name, detail, viewing }) {
  return (
    <div className={styles.collaborator}>
      {avatar}
      <span className={styles.collaboratorName}>{name}</span>
      {viewing ? (
        <span className={styles.viewingBadge}>
          <span className={styles.viewingDot} />viewing
        </span>
      ) : (
        <span className={styles.collaboratorDetail}>{detail}</span>
      )}
    </div>
  )
}
