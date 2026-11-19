import { useEffect, useRef, useCallback } from 'react'
import Icon from '../Icon'
import Spinner from '../Spinner'
import Tooltip from '../Tooltip'
import relativeTime from '../../lib/relativeTime'
import styles from './SyncStatusBar.module.css'

const STATUS_CONFIG = {
  connected: { label: 'Connected', color: 'var(--status-success-text)', icon: 'checkmark.circle.fill' },
  connecting: { label: 'Connecting...', color: 'var(--status-warn-text)', icon: 'arrow.clockwise' },
  syncing: { label: 'Syncing...', color: 'var(--status-info-text)', icon: 'arrow.clockwise' },
  error: { label: 'Disconnected', color: 'var(--status-danger-text)', icon: 'exclamationmark.triangle' },
  disconnected: { label: 'Offline', color: 'var(--status-debug-text)', icon: 'nosign' },
}

export default function SyncStatusBar({ status, lastSyncAt, onOpenConsole, onRefresh, isSyncing }) {
  // An in-flight sync (e.g. the initial bulk import) takes precedence over the
  // steady-state account status, so the bar shows an indeterminate "Syncing…"
  // while it runs instead of a static "Connected".
  const effectiveStatus = isSyncing ? 'syncing' : status
  const config = STATUS_CONFIG[effectiveStatus] || STATUS_CONFIG.disconnected
  const dotRef = useRef(null)

  useEffect(() => {
    if (dotRef.current) {
      dotRef.current.style.setProperty('--status-color', config.color)
    }
  }, [config.color])

  const timeAgo = lastSyncAt ? relativeTime(lastSyncAt) : null

  const handleRefresh = useCallback((e) => {
    e.stopPropagation()
    if (onRefresh && !isSyncing) onRefresh()
  }, [onRefresh, isSyncing])

  return (
    <div className={styles.bar}>
      <Tooltip content="Open sync console">
        <button className={styles.statusButton} onClick={onOpenConsole}>
          <span ref={dotRef} className={`${styles.dot} ${effectiveStatus === 'syncing' || effectiveStatus === 'connecting' ? styles.dotPulse : ''}`} />
          <span className={styles.label}>{config.label}</span>
          {timeAgo && <span className={styles.time}>{timeAgo}</span>}
          <Icon name="terminal" size={12} className={styles.consoleIcon} />
        </button>
      </Tooltip>
      {onRefresh && (
        <Tooltip content={isSyncing ? 'Syncing…' : 'Resync this channel'}>
          <button
            className={styles.refreshButton}
            onClick={handleRefresh}
            disabled={isSyncing}
            aria-label="Resync this channel"
          >
            {isSyncing
              ? <Spinner variant="icon" icon="arrow.clockwise" size={12} color="currentColor" label="Syncing" />
              : <Icon name="arrow.clockwise" size={12} />}
          </button>
        </Tooltip>
      )}
    </div>
  )
}
