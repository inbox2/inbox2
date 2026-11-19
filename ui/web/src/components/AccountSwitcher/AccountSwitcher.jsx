import { useState, useRef, useEffect, useCallback } from 'react'
import { DndContext, closestCenter, PointerSensor, useSensor, useSensors } from '@dnd-kit/core'
import { SortableContext, verticalListSortingStrategy, arrayMove } from '@dnd-kit/sortable'
import useSortableNode from '../../hooks/useSortableNode'
import useUnreadStore, { formatBadge } from '../../stores/unreadStore'
import useDismiss from '../../hooks/useDismiss'
import Icon from '../Icon'
import { initialsDataUri } from '../../lib/initialsIcon'
import { PROVIDER, providerIcon } from '../../lib/providerTypes'
import styles from './AccountSwitcher.module.css'

function ProviderIcon({ type, iconUrl, avatarUrl, name, size = 20 }) {
  // Remote avatars (e.g. googleusercontent photos) can fail to load; fall back
  // to the provider icon so a broken-image glyph is never shown. Track the
  // failed URL (not a bool) so a new avatarUrl is retried after a reorder.
  const [failedSrc, setFailedSrc] = useState(null)
  const isAvatar = !!avatarUrl && failedSrc !== avatarUrl
  // An MX domain (provider_type 'inbox2') with no custom icon shows its own
  // initials monogram rather than the generic inbox2 cube.
  const fallback = (type === PROVIDER.INBOX2 && name)
    ? initialsDataUri(name)
    : providerIcon(type)
  const isCustom = !!iconUrl && !isAvatar
  const src = isAvatar ? avatarUrl : (iconUrl || fallback)
  return (
    <img
      src={src}
      alt={type}
      width={size}
      height={size}
      onError={() => { if (avatarUrl) setFailedSrc(avatarUrl) }}
      className={`${styles.providerIcon} ${isAvatar ? styles.providerIconAvatar : ''} ${isCustom ? styles.providerIconCustom : ''}`}
    />
  )
}

export { ProviderIcon }

function SortableAccountItem({ acct, isActive, onSwitch, unreadCount }) {
  const { ref, attributes, listeners, isDragging } = useSortableNode(acct.key)

  return (
    <button
      ref={ref}
      className={`${styles.dropdownItem} ${isActive ? styles.dropdownItemActive : ''} ${isDragging ? styles.dropdownItemDragging : ''}`}
      onClick={() => onSwitch(acct.key)}
      {...attributes}
    >
      <span className={styles.dragHandle} {...listeners}>
        <Icon name="line.3.horizontal" size={10} />
      </span>
      <ProviderIcon type={acct.provider_type} iconUrl={acct.icon_url} avatarUrl={acct.avatar_url} name={acct.display_name || acct.email_address} size={16} />
      <div className={styles.dropdownItemInfo}>
        <span className={styles.dropdownItemName}>{acct.display_name}</span>
        <span className={styles.dropdownItemEmail}>{acct.email_address}</span>
      </div>
      {unreadCount > 0 && (
        <span className={styles.unreadBadge}>{formatBadge(unreadCount)}</span>
      )}
      <StatusDot status={acct.status} />
    </button>
  )
}

export default function AccountSwitcher({ accounts, activeKey, onSwitch, onAddAccount, onUnified, isUnified, onReorder }) {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  const unreadByChannel = useUnreadStore(s => s.byChannel)

  const close = useCallback(() => setOpen(false), [])
  useDismiss(ref, close, open)

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } })
  )

  const handleDragEnd = useCallback((event) => {
    const { active, over } = event
    if (!over || active.id === over.id) return
    const oldIndex = accounts.findIndex(a => a.key === active.id)
    const newIndex = accounts.findIndex(a => a.key === over.id)
    if (oldIndex === -1 || newIndex === -1) return
    const reordered = arrayMove(accounts, oldIndex, newIndex)
    onReorder?.(reordered.map(a => a.key))
  }, [accounts, onReorder])

  const active = isUnified
    ? { display_name: 'Unified Inbox', email_address: `${accounts.length} channels`, provider_type: 'unified', status: 'connected' }
    : (accounts.find(a => a.key === activeKey) || accounts[0])

  return (
    <div className={styles.switcher} ref={ref}>
      <button className={styles.trigger} onClick={() => setOpen(!open)}>
        {active ? (
          <>
            {isUnified
              ? <img src="/logo-cube.png" alt="Unified" width={18} height={18} className={styles.providerIcon} />
              : <ProviderIcon type={active.provider_type} iconUrl={active.icon_url} avatarUrl={active.avatar_url} name={active.display_name || active.email_address} size={18} />
            }
            <div className={styles.triggerInfo}>
              <span className={styles.triggerName}>{active.display_name}</span>
              <span className={styles.triggerEmail}>{active.email_address}</span>
            </div>
            <Icon name="chevron.up.chevron.down" size={10} className={styles.triggerChevron} />
          </>
        ) : (
          <>
            <Icon name="at.badge.plus" size={18} className={styles.triggerIconEmpty} />
            <span className={styles.triggerEmpty}>Connect a mailbox</span>
          </>
        )}
      </button>

      {open && (
        <div className={styles.dropdown}>
          {onUnified && (
            <>
              <button
                className={`${styles.dropdownItem} ${isUnified ? styles.dropdownItemActive : ''}`}
                onClick={() => { onUnified(); setOpen(false) }}
              >
                <img src="/logo-cube.png" alt="Unified" width={16} height={16} className={styles.providerIcon} />
                <div className={styles.dropdownItemInfo}>
                  <span className={styles.dropdownItemName}>Unified Inbox</span>
                  <span className={styles.dropdownItemEmail}>All channels</span>
                </div>
              </button>
              <div className={styles.dropdownLabel}>Accounts</div>
            </>
          )}
          {!onUnified && <div className={styles.dropdownLabel}>Accounts</div>}
          <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={handleDragEnd}>
            <SortableContext items={accounts.map(a => a.key)} strategy={verticalListSortingStrategy}>
              {accounts.map(acct => (
                <SortableAccountItem
                  key={acct.key}
                  acct={acct}
                  isActive={!isUnified && acct.key === activeKey}
                  onSwitch={(key) => { onSwitch(key); setOpen(false) }}
                  unreadCount={unreadByChannel[acct.key] || 0}
                />
              ))}
            </SortableContext>
          </DndContext>
          {onAddAccount && (
            <button className={styles.dropdownAdd} onClick={() => { onAddAccount(); setOpen(false) }}>
              <Icon name="at.badge.plus" size={14} className={styles.dropdownAddIcon} />
              Add account
            </button>
          )}
        </div>
      )}
    </div>
  )
}

function StatusDot({ status }) {
  const ref = useRef(null)
  const color = status === 'connected' ? 'var(--status-success-text)' : status === 'connecting' ? 'var(--status-warn-text)' : status === 'needs_reauth' ? 'var(--status-caution-text)' : status === 'error' ? 'var(--status-danger-text)' : 'var(--status-debug-text)'
  const label = status === 'connected' ? 'Connected' : status === 'connecting' ? 'Connecting' : status === 'needs_reauth' ? 'Sign-in expired. Reconnect in Settings.' : status === 'error' ? 'Error' : 'Offline'

  useEffect(() => {
    if (ref.current) ref.current.style.setProperty('--dot-bg', color)
  }, [color])

  return <span ref={ref} className={styles.statusDot} title={label} />
}
