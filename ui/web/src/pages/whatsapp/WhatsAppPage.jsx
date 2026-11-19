import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router'
import { DndContext, closestCenter, KeyboardSensor, PointerSensor, useSensor, useSensors } from '@dnd-kit/core'
import { SortableContext, horizontalListSortingStrategy, arrayMove, sortableKeyboardCoordinates } from '@dnd-kit/sortable'
import useSortableNode from '../../hooks/useSortableNode'
import Icon from '../../components/Icon'
import SocialListRow from '../../components/SocialListRow/SocialListRow'
import WaChatPane from '../../components/WaChatPane/WaChatPane'
import ChannelEmptyState from '../../components/ChannelEmptyState/ChannelEmptyState'
import { PROVIDER } from '../../lib/providerTypes'
import { WA_OPEN_COLUMNS } from '../../lib/storageKeys'
import { waChats, waMediaUrl, useLocalWhatsAppEnabled, useWaStatus, isNoAccess, waErrorText, waOpenPrivacySettings, waPollNow } from '../../lib/localWhatsApp'
import layoutStyles from '../../styles/layout.module.css'
// The unified inbox's lanes (gradients, dot grid, header), so chats read as columns too.
import laneStyles from '../../components/ListViewColumns/ListViewColumns.module.css'
import styles from './WhatsAppPage.module.css'

// An open chat column that reorders: hold its header, then drag it sideways.
function SortableColumn({ id, children }) {
  const { ref, attributes, listeners, isDragging } = useSortableNode(id)
  return (
    <div ref={ref} className={`${laneStyles.column} ${styles.column}${isDragging ? ` ${styles.dragging}` : ''}`} data-chat-column={id}>
      {children({ ...attributes, ...listeners })}
    </div>
  )
}

function listTime(ms) {
  const d = new Date(ms)
  const now = new Date()
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  return d.toLocaleDateString([], now.getFullYear() === d.getFullYear() ? { day: 'numeric', month: 'short' } : undefined)
}

// The open columns, remembered per device: [{ id, anchor }] (anchor = a search hit's message, not kept).
function readOpen() {
  try {
    const v = JSON.parse(localStorage.getItem(WA_OPEN_COLUMNS) || '[]')
    return Array.isArray(v) ? v.filter(c => Number.isInteger(c?.id)).map(c => ({ id: c.id, anchor: null })) : []
  } catch {
    return []
  }
}
function writeOpen(open) {
  try { localStorage.setItem(WA_OPEN_COLUMNS, JSON.stringify(open.map(c => ({ id: c.id })))) } catch { /* private window */ }
}

// How long a read made here outlasts polls that still say unread (WhatsApp saving it).
const READ_HOLD_MS = 30_000

/**
 * Local WhatsApp (desktop): WhatsApp Desktop's chats on this Mac, read live
 * from its own database. The chat list on the left toggles chats in and out
 * of side-by-side columns (the unified inbox's lanes); each column's ✕ closes
 * it too. `?chat=<id>&msg=<id>` (a search hit, a Lore item) opens that chat's
 * column at the message.
 */
export default function WhatsAppPage() {
  const enabled = useLocalWhatsAppEnabled()
  const { version, available, error, loaded } = useWaStatus()
  const navigate = useNavigate()
  const [params, setParams] = useSearchParams()
  const [rawChats, setChats] = useState([])
  // Read here (the WhatsApp button): chat id → its last_at then. Shown read at once,
  // and polls landing before WhatsApp has saved the read can't bring it back; a
  // newer message (last_at moves) or READ_HOLD_MS passing makes it unread again.
  const [readAt, setReadAt] = useState(() => new Map())
  const dropRead = useCallback((ids) => setReadAt(m => { const n = new Map(m); ids.forEach(id => n.delete(id)); return n }), [])
  const markRead = useCallback((chat) => {
    setReadAt(m => new Map(m).set(chat.id, chat.last_at))
    // Only the override this click made: a later read of the same chat keeps its own.
    setTimeout(() => setReadAt(m => {
      if (m.get(chat.id) !== chat.last_at) return m
      const n = new Map(m); n.delete(chat.id); return n
    }), READ_HOLD_MS)
    waPollNow()
  }, [])
  // Once a poll shows the read, the override has done its job.
  useEffect(() => {
    const done = [...readAt.keys()].filter(id => rawChats.some(c => c.id === id && c.unread === 0))
    // eslint-disable-next-line react-hooks/set-state-in-effect -- drops overrides the data now carries
    if (done.length) dropRead(done)
  }, [rawChats, readAt, dropRead])
  const chats = useMemo(() => (readAt.size
    ? rawChats.map(c => (c.unread !== 0 && readAt.get(c.id) === c.last_at ? { ...c, unread: 0 } : c))
    : rawChats), [rawChats, readAt])
  // The chat list has answered at least once (the empty state waits for it, not for the status poll).
  const [chatsLoaded, setChatsLoaded] = useState(false)
  const [filter, setFilter] = useState('')
  const [showArchived, setShowArchived] = useState(false)
  const [open, setOpen] = useState(readOpen)
  // Keyboard cursor in the list (↑/↓ move it, Enter/Space toggles its column).
  const [cursor, setCursor] = useState(null)
  // The chat list failed to load (shown with a retry; `retry` re-runs the load).
  const [chatsError, setChatsError] = useState(null)
  const [retry, setRetry] = useState(0)
  const listRef = useRef(null)
  const columnsRef = useRef(null)

  useEffect(() => { writeOpen(open) }, [open])

  useEffect(() => {
    if (!enabled) navigate('/mail', { replace: true })
  }, [enabled, navigate])

  // Reload the list whenever WhatsApp changes (the status poll moves `version`).
  useEffect(() => {
    if (!available) return undefined
    let cancelled = false
    waChats()
      .then(c => { if (!cancelled) { setChats(c); setChatsError(null); setChatsLoaded(true) } })
      .catch(e => { if (!cancelled) setChatsError(waErrorText(e?.message || e)) })
    return () => { cancelled = true }
  }, [available, version, retry])

  // A link in (?chat=&msg=): open that chat's column at the message, then drop the params.
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: the URL hands over a chat to open */
  useEffect(() => {
    const id = Number(params.get('chat')) || null
    if (!id) return
    const anchor = Number(params.get('msg')) || null
    setOpen(o => [...o.filter(c => c.id !== id), { id, anchor }])
    setCursor(id)
    setParams({}, { replace: true })
  }, [params, setParams])
  /* eslint-enable react-hooks/set-state-in-effect */

  const toggle = useCallback((id) => {
    setCursor(id)
    setOpen(o => (o.some(c => c.id === id) ? o.filter(c => c.id !== id) : [...o, { id, anchor: null }]))
  }, [])
  const close = useCallback((id) => setOpen(o => o.filter(c => c.id !== id)), [])
  // Hold (200ms) before a drag starts: a quick click on the header's buttons stays a click.
  // Keyboard: Tab to a column header, Space to lift, ←/→ to move, Space to drop.
  const dndSensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { delay: 200, tolerance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )
  const reorder = useCallback(({ active, over }) => {
    if (!over || active.id === over.id) return
    setOpen(o => arrayMove(o, o.findIndex(c => c.id === active.id), o.findIndex(c => c.id === over.id)))
  }, [])

  // A newly opened column scrolls into view at the right end of the strip.
  const lastOpen = open[open.length - 1]?.id
  useEffect(() => {
    if (lastOpen) columnsRef.current?.querySelector(`[data-chat-column="${lastOpen}"]`)?.scrollIntoView({ inline: 'nearest', behavior: 'smooth' })
  }, [lastOpen])

  const visible = useMemo(() => {
    const q = filter.trim().toLowerCase()
    return chats.filter(c => (q ? c.name.toLowerCase().includes(q) : c.archived === showArchived))
  }, [chats, filter, showArchived])
  const archivedCount = useMemo(() => chats.filter(c => c.archived).length, [chats])
  const byId = useMemo(() => new Map(chats.map(c => [c.id, c])), [chats])
  const openIds = useMemo(() => new Set(open.map(c => c.id)), [open])

  // The cursor stays on a chat the list shows: filtering it away moves it to the first one.
  const cursorShown = visible.some(c => c.id === cursor)
  /* eslint-disable react-hooks/set-state-in-effect -- intentional: keep the cursor on a visible chat */
  useEffect(() => {
    if (!cursorShown && cursor !== null) setCursor(visible[0]?.id ?? null)
  }, [cursorShown, cursor, visible])
  /* eslint-enable react-hooks/set-state-in-effect */

  const onListKey = (e) => {
    if ((e.key === 'Enter' || e.key === ' ') && cursorShown) {
      e.preventDefault()
      toggle(cursor)
      return
    }
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
    e.preventDefault()
    const i = visible.findIndex(c => c.id === cursor)
    const next = visible[Math.max(0, Math.min(visible.length - 1, i + (e.key === 'ArrowDown' ? 1 : -1)))]
    if (next) setCursor(next.id)
  }
  useEffect(() => {
    listRef.current?.querySelector('[data-cursor="true"]')?.scrollIntoView({ block: 'nearest' })
  }, [cursor])

  if (loaded && !available) {
    return (
      <div className={layoutStyles.body}>
        <div className={styles.unavailable}>
          <img src="/channels/whatsapp.svg" alt="" width="48" height="48" />
          <strong>Can't read WhatsApp on this Mac</strong>
          <span>{waErrorText(error)}</span>
          {isNoAccess(error)
            ? <button type="button" className={styles.archivedToggle} onClick={() => waOpenPrivacySettings()}>Open Full Disk Access</button>
            : <span>Install WhatsApp Desktop and sign in.</span>}
        </div>
      </div>
    )
  }

  // Columns whose chat is known (a chat that left WhatsApp drops out).
  const columns = open.filter(c => byId.has(c.id))

  return (
    <div className={layoutStyles.body}>
      <div className={styles.layout}>
        <aside className={styles.list}>
          <div className={styles.filterRow}>
            <Icon name="magnifyingglass" size={11} className={styles.filterIcon} />
            <input
              className={styles.filter}
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder="Filter chats"
              aria-label="Filter chats"
            />
          </div>
          {!filter && archivedCount > 0 && (
            <button type="button" className={styles.archivedToggle} onClick={() => setShowArchived(v => !v)}>
              <Icon name={showArchived ? 'chevron.left' : 'archivebox'} size={11} />
              {showArchived ? 'Back to chats' : `Archived (${archivedCount})`}
            </button>
          )}
          {visible.length > 0 && <div
            ref={listRef}
            className={styles.rows}
            tabIndex={0}
            onKeyDown={onListKey}
            // Tabbing in puts the cursor on the first chat, so focus is always visible.
            onFocus={(e) => { if (e.target === e.currentTarget && !cursorShown) setCursor(visible[0]?.id ?? null) }}
            role="listbox"
            aria-multiselectable="true"
            aria-label="WhatsApp chats. Enter opens or closes a chat's column"
            aria-activedescendant={visible.some(c => c.id === cursor) ? `wa-chat-${cursor}` : undefined}
          >
            {visible.map(c => (
              <div
                key={c.id}
                id={`wa-chat-${c.id}`}
                role="option"
                aria-selected={openIds.has(c.id)}
                data-cursor={c.id === cursor}
                className={[openIds.has(c.id) && styles.open, c.id === cursor && styles.cursor].filter(Boolean).join(' ') || undefined}
              >
                <SocialListRow
                  sender={c.name}
                  avatar={waMediaUrl(c.avatar)}
                  channel={PROVIDER.WHATSAPP}
                  preview={c.last_text || ''}
                  time={listTime(c.last_at)}
                  unread={c.unread !== 0}
                  count={c.unread > 1 ? c.unread : 0}
                  pinned={c.pinned}
                  onClick={() => toggle(c.id)}
                />
              </div>
            ))}
          </div>}
          {/* Status lives outside the listbox, which holds only options (and exists only with some). */}
          {chatsError && (
            <div className={styles.empty} role="alert">
              Couldn't load your chats: {chatsError}
              <button type="button" className={styles.archivedToggle} onClick={() => setRetry(n => n + 1)}>Try again</button>
            </div>
          )}
          {!chatsError && !chatsLoaded && <div className={styles.empty} role="status">Loading chats…</div>}
          {!chatsError && chatsLoaded && visible.length === 0 && <div className={styles.empty} role="status">No chats</div>}
        </aside>
        <div ref={columnsRef} className={`${laneStyles.columnsContainer} ${styles.columns}`}>
          {columns.length === 0 && (
            <div className={styles.noColumns}>
              <ChannelEmptyState
                iconSrc="/channels/whatsapp.svg"
                title="No chats open"
                message="Click a chat to open it as a column. Click it again, or its ✕, to close it."
              />
            </div>
          )}
          <DndContext sensors={dndSensors} collisionDetection={closestCenter} onDragEnd={reorder}>
            <SortableContext items={columns.map(c => c.id)} strategy={horizontalListSortingStrategy}>
              {columns.map(({ id, anchor }) => (
                <SortableColumn key={`${id}:${anchor || ''}`} id={id}>
                  {(dragHandle) => <WaChatPane chat={byId.get(id)} anchorId={anchor} onClose={() => close(id)} onRead={markRead} dragHandle={dragHandle} />}
                </SortableColumn>
              ))}
            </SortableContext>
          </DndContext>
        </div>
      </div>
    </div>
  )
}
