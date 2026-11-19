import { useEffect, useRef } from 'react'
import Modal from '../Modal/Modal'
import Icon from '../Icon'
import Spinner from '../Spinner'
import IconButton from '../IconButton'
import Tooltip from '../Tooltip'
import useCopyToClipboard from '../../hooks/useCopyToClipboard'
import { ProviderIcon } from '../AccountSwitcher/AccountSwitcher'
import { PROVIDER } from '../../lib/providerTypes'
import styles from './SyncConsole.module.css'

export default function SyncConsole({ open, onClose, account, folders, syncStatus, logs, diagnostics, syncing }) {
  const logEndRef = useRef(null)

  // Order by timestamp: backfilled (mid-sync) events can arrive after newer
  // live ones, so sort rather than trust insertion order.
  const orderedLogs = [...(logs || [])].sort((a, b) => (a.t || 0) - (b.t || 0))

  useEffect(() => {
    if (logEndRef.current) {
      logEndRef.current.scrollIntoView({ behavior: 'smooth' })
    }
  }, [logs?.length])

  // Escape is handled by <Modal> (capture-phase). Don't add a second listener.

  const capabilities = syncStatus?.capabilities || []
  const folderList = folders || []
  const isOAuth = account?.provider_type === PROVIDER.GMAIL || account?.provider_type === PROVIDER.MICROSOFT
  const diag = diagnostics || {}

  return (
    <Modal
      open={open}
      onClose={onClose}
      showClose={false}
      overlayClassName={styles.overlay}
      className={styles.panel}
    >
        <div className={styles.header}>
          <div className={styles.headerLeft}>
            {account && <ProviderIcon type={account.provider_type} size={16} />}
            <h3 className={styles.title}>
              Sync console
              {account && <span className={styles.titleAccount}>{account.email_address}</span>}
            </h3>
            {syncing && (
              <Spinner variant="icon" icon="arrow.triangle.2.circlepath" size={13} label="Syncing" />
            )}
          </div>
          <IconButton icon="xmark" onClick={onClose} aria-label="Close" />
        </div>

        <div className={styles.body}>
          {/* ── Sync state (OAuth providers) ─── */}
          {isOAuth && (
            <section className={styles.section}>
              <h4 className={styles.sectionTitle}>Sync state</h4>
              <div className={styles.infoGrid}>
                <InfoRow label="Provider" value={diag.provider || account?.provider_type || '—'} />
                <InfoRow label="Status" value={
                  <span className={styles.statusBadge} data-status={account?.status}>
                    {account?.status || 'disconnected'}
                  </span>
                } />
                <InfoRow label="Adapter running" value={
                  <span className={diag.running ? styles.valGreen : styles.valRed}>
                    {diag.running ? 'Yes' : 'No'}
                  </span>
                } />
                <InfoRow label="Polling active" value={
                  <span className={diag.polling ? styles.valGreen : styles.valRed}>
                    {diag.polling ? 'Yes' : 'No'}
                  </span>
                } />
                {account?.provider_type === PROVIDER.GMAIL && (
                  <InfoRow label="History ID" value={diag.historyId || 'none'} />
                )}
                {account?.provider_type === PROVIDER.MICROSOFT && (
                  <InfoRow label="Delta links" value={diag.deltaLinks ?? '—'} />
                )}
                {diag.inboxMessagesTotal != null && (
                  <InfoRow label="Gmail inbox total" value={diag.inboxMessagesTotal.toLocaleString()} />
                )}
              </div>
              {account?.error_message && (
                <div className={styles.errorMessage}>{account.error_message}</div>
              )}
            </section>
          )}

          {/* ── Local database stats ─── */}
          {isOAuth && (
            <section className={styles.section}>
              <h4 className={styles.sectionTitle}>Local database</h4>
              <div className={styles.infoGrid}>
                <InfoRow label="Conversations" value={diag.localConversations?.toLocaleString()} />
                <InfoRow label="Messages" value={diag.localMessages?.toLocaleString()} />
                <InfoRow label="Provider states" value={diag.providerStates?.toLocaleString()} />
                <InfoRow label="Synced folders" value={diag.folderCount} />
              </div>
            </section>
          )}

          {/* ── Connection info (IMAP only) ─── */}
          {!isOAuth && (
            <section className={styles.section}>
              <h4 className={styles.sectionTitle}>Connection</h4>
              <div className={styles.infoGrid}>
                <InfoRow label="Host" value={account?.host || '—'} />
                <InfoRow label="Port" value={account?.port || '—'} />
                <InfoRow label="TLS" value={account?.use_tls ? 'Yes' : 'No'} />
                <InfoRow label="Status" value={
                  <span className={styles.statusBadge} data-status={account?.status}>
                    {account?.status || 'disconnected'}
                  </span>
                } />
              </div>
              {account?.error_message && (
                <div className={styles.errorMessage}>{account.error_message}</div>
              )}
            </section>
          )}

          {/* ── Capabilities (IMAP only) ─── */}
          {capabilities.length > 0 && (
            <section className={styles.section}>
              <h4 className={styles.sectionTitle}>Capabilities</h4>
              <div className={styles.capList}>
                {capabilities.map((cap, i) => (
                  <span key={i} className={styles.capBadge}>{cap}</span>
                ))}
              </div>
            </section>
          )}

          {/* ── Folders ─── */}
          <section className={styles.section}>
            <h4 className={styles.sectionTitle}>Folders ({folderList.length})</h4>
            <div className={styles.folderTable}>
              <div className={styles.folderTableHead}>
                <span>Name</span>
                <span>Role</span>
                <span>{isOAuth ? 'Label ID' : 'Synced UIDs'}</span>
                <span>Messages</span>
                <span>Enabled</span>
              </div>
              {folderList.map(f => (
                <div key={f.key} className={styles.folderRow}>
                  <span className={styles.folderName}>{f.provider_name}</span>
                  <span className={styles.folderRole}>{f.well_known_role || '—'}</span>
                  <span className={styles.folderUid}>
                    {isOAuth ? (f.provider_label_id || '—') : (f.last_synced_uid || 0)}
                  </span>
                  <span className={styles.folderUid}>
                    {(diag.folderMessageCounts?.[f.key] ?? 0).toLocaleString()}
                  </span>
                  <span className={f.sync_enabled ? styles.folderEnabled : styles.folderDisabled}>
                    {f.sync_enabled ? 'Yes' : 'No'}
                  </span>
                </div>
              ))}
              {folderList.length === 0 && (
                <div className={styles.folderRow}>
                  <span className={styles.folderEmpty}>No folders synced yet</span>
                </div>
              )}
            </div>
          </section>

          {/* ── Sync log ─── */}
          <section className={styles.logSection}>
            <SyncLogHeader logs={orderedLogs} />
            <div className={styles.logWindow}>
              {orderedLogs.map((entry, i) => (
                <div key={i} className={styles.logEntry}>
                  <span className={styles.logTime}>{entry.time}</span>
                  <span className={`${styles.logLevel} ${styles[`log${entry.level}`]}`}>
                    {entry.level}
                  </span>
                  <span className={styles.logMessage}>{entry.message}</span>
                </div>
              ))}
              {orderedLogs.length === 0 && (
                <div className={styles.logEmpty}>No log entries yet. Connect an account to see sync activity.</div>
              )}
              <div ref={logEndRef} />
            </div>
          </section>
        </div>
    </Modal>
  )
}

function SyncLogHeader({ logs }) {
  const [copied, copy] = useCopyToClipboard()

  const handleCopy = () => {
    const text = (logs || [])
      .map(e => `[${e.time}] ${e.level} ${e.message}`)
      .join('\n')
    copy(text)
  }

  return (
    <div className={styles.sectionHeader}>
      <h4 className={styles.sectionTitle}>Sync log</h4>
      <Tooltip content="Copy log to clipboard">
        <button className={styles.copyBtn} onClick={handleCopy}>
          <Icon name={copied ? 'checkmark' : 'doc.on.doc'} size={12} />
          {copied ? 'Copied' : 'Copy'}
        </button>
      </Tooltip>
    </div>
  )
}

function InfoRow({ label, value }) {
  return (
    <div className={styles.infoRow}>
      <span className={styles.infoLabel}>{label}</span>
      <span className={styles.infoValue}>{value}</span>
    </div>
  )
}
