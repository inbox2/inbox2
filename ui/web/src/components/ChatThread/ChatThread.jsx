import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { displayName as senderName } from '../../lib/emailAddress'
import { messagePlainText } from '../../lib/messageText'
import { linkifyText } from '../../lib/linkifyText'
import { brandFor, brandVars } from '../../lib/providerTypes'
import ChatBubble from './ChatBubble'
import Icon from '../Icon'
import styles from './ChatThread.module.css'

// Show a centered date/time separator when the gap to the previous message
// exceeds this, or the calendar day changes.
const GROUP_GAP_MS = 15 * 60 * 1000

function sameDay(a, b) {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

function sepLabel(d) {
  const now = new Date()
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  if (sameDay(d, now)) return time
  return `${d.toLocaleDateString([], { month: 'short', day: 'numeric' })} · ${time}`
}

function bubbleTime(d) {
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

// The social-DM counterpart to the email message list: a brand-themed,
// scrollable stream of chat bubbles. Owns its own scroll-to-bottom (chat
// convention) and timestamp grouping. The header toolbar, SmartReplyBar and
// Composer stay in ConversationDetail (shared with email).
//
// Optional, for read-through chats (local WhatsApp): per-message `sender_label` /
// `avatar_url` (group chats name every inbound run), `system` rows (group events),
// attachments with an `onOpen`, and `hasEarlier` + `onLoadEarlier` paging.
// `narrow` centres the bubbles in a messenger-width column inside a wide pane;
// `bare` drops the thread's own scrim so a lane's background shows through.
// `scrollToId` brings a row (bubble or system line) into view once, by its message id.
// `onOpenMedia(a)`: typed media in a bubble was clicked.
export default function ChatThread({ conversation, enrichingKeys, focusedMsgIndex = -1, scrollToId = null, hasEarlier = false, onLoadEarlier, onOpenMedia, narrow = false, bare = false }) {
  const scrollRef = useRef(null)
  const wrapRef = useRef(null)

  // Apply the per-platform brand as CSS custom properties (no inline styles).
  useEffect(() => {
    const el = wrapRef.current
    if (!el) return
    for (const [name, value] of brandVars(brandFor(conversation))) {
      el.style.setProperty(name, value)
    }
  // brandFor only reads channel/providerType — re-run when the surface changes.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversation.channel, conversation.providerType])

  // Build the render list: messages interleaved with date/time separators.
  const rows = useMemo(() => {
    const msgs = conversation.messages ?? []
    const out = []
    let prevDate = null
    // Bubble number (system rows aren't bubbles): what focusedMsgIndex counts, for
    // both the highlight and the scroll-into-view below.
    let bubble = 0
    msgs.forEach((msg, i) => {
      const date = new Date(msg.created_at)
      const isInbound = !!msg.is_inbound
      const gap = prevDate ? date - prevDate : Infinity
      const newGroup = gap > GROUP_GAP_MS || (prevDate && !sameDay(date, prevDate))
      if (newGroup) {
        out.push({ type: 'sep', id: `sep-${i}`, label: sepLabel(date) })
      }
      if (msg.system) {
        out.push({ type: 'sep', system: true, id: msg.id || `sys-${i}`, label: msg.body })
        prevDate = date
        return
      }
      // A run is consecutive inbound bubbles from one sender (groups have many).
      const sameRun = (other) => other && !other.system && !!other.is_inbound === isInbound && other.sender_label === msg.sender_label
      // Avatar on the LAST bubble of an inbound run (WhatsApp/Messenger style),
      // bottom-aligned to that bubble; the sender's name on the FIRST.
      const showAvatar = isInbound && (i === msgs.length - 1 || !sameRun(msgs[i + 1]))
      out.push({
        type: 'msg',
        id: msg.id || msg.key || `m-${i}`,
        index: bubble++,
        isInbound,
        showAvatar,
        time: bubbleTime(date),
        isDraft: !!msg.is_draft,
        // Sent from here, not yet in the source (local WhatsApp's instant bubble).
        pending: !!msg.pending,
        sender: msg.sender_label || senderName(msg.from_address) || msg.from_address || '',
        senderLabel: isInbound && msg.sender_label && (newGroup || !sameRun(msgs[i - 1])) ? msg.sender_label : null,
        avatarSrc: msg.avatar_url || conversation.from_avatar || null,
        bodyHtml: linkifyText(messagePlainText(msg)),
        attachments: msg.attachments,
        reaction: msg.reaction || null,
        deleted: !!msg.deleted,
        enriching: enrichingKeys?.has(msg.key || msg.id),
      })
      prevDate = date
    })
    return out
  }, [conversation.messages, conversation.from_avatar, enrichingKeys])

  // Scroll to the latest message on open, and when a new one arrives while the
  // reader is at the bottom (or it's their own); someone scrolled up into older
  // messages stays put. Older messages prepended (Load earlier) hold the place.
  const FOLLOW_SLACK = 120
  const edges = useRef({ conv: null, first: null, last: null, height: 0 })
  // New messages arrived below while the reader was scrolled up (the pill).
  const [newBelow, setNewBelow] = useState(false)
  const toBottom = () => {
    const el = scrollRef.current
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
    setNewBelow(false)
  }
  // Pinned to the bottom: anything that grows the thread after the first paint
  // (images and video posters loading, fonts, link previews, the column itself
  // resizing) and a pinned thread follows it down. Scrolling away (or opening at
  // a search hit) unpins it; scrolling back down pins again.
  const stick = useRef(true)
  const onScroll = (e) => {
    const el = e.currentTarget
    const near = el.scrollHeight - el.scrollTop - el.clientHeight < FOLLOW_SLACK
    stick.current = near
    if (newBelow && near) setNewBelow(false)
  }
  useEffect(() => {
    const el = scrollRef.current
    if (!el) return undefined
    const ro = new ResizeObserver(() => { if (stick.current) el.scrollTop = el.scrollHeight })
    ro.observe(el)
    for (const child of el.children) ro.observe(child)
    return () => ro.disconnect()
  }, [rows])
  useLayoutEffect(() => {
    const el = scrollRef.current
    if (!el) return
    const msgs = rows.filter(r => r.type === 'msg')
    const first = msgs[0]?.id ?? null
    // The newest thing in the thread, a group event (system row) included: one
    // arriving last is new too, and gets followed or announced like a message.
    const newest = [...rows].reverse().find(r => r.type === 'msg' || r.system)
    const last = newest?.id ?? null
    const prev = edges.current
    const atBottom = prev.height - el.scrollTop - el.clientHeight < FOLLOW_SLACK
    const ownNewest = newest?.type === 'msg' && !newest.isInbound
    // A new conversation, or the first messages of this one (it mounts empty while
    // they load): open at the bottom, pinned.
    if (prev.conv !== conversation.id || (prev.last == null && last != null)) {
      el.scrollTop = el.scrollHeight
      stick.current = !scrollToId
      setNewBelow(false)
    }
    else if (prev.last !== last && prev.last != null) {
      if (atBottom || ownNewest) el.scrollTop = el.scrollHeight
      // Reading further up: keep the place and say something new arrived.
      else setNewBelow(true)
    }
    else if (prev.first !== first) el.scrollTop += el.scrollHeight - prev.height
    edges.current = { conv: conversation.id, first, last, height: el.scrollHeight }
  // scrollToId is read for the pin only; the hit has its own effect below.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [conversation.id, rows])

  // A search hit: scroll its row (bubble or system line) to the middle, once it's rendered.
  const scrolledTo = useRef(null)
  useEffect(() => {
    if (!scrollToId || scrolledTo.current === scrollToId) return
    const el = scrollRef.current?.querySelector(`[data-row-id="${scrollToId}"]`)
    if (!el) return
    scrolledTo.current = scrollToId
    stick.current = false // reading at the hit, not following the bottom
    el.scrollIntoView({ block: 'center' })
  }, [scrollToId, rows])

  // Keyboard message-stepping parity (F4) and search hits: bring the focused
  // bubble into view when the focus moves to another message, not when its
  // index shifts because older messages were prepended (Load earlier).
  const focusedId = rows.find(r => r.type === 'msg' && r.index === focusedMsgIndex)?.id ?? null
  useEffect(() => {
    if (focusedId == null) return
    const el = scrollRef.current?.querySelectorAll('[data-chat-bubble]')[focusedMsgIndex]
    el?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  // Keyed on the message, not its index (see above).
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusedId])

  return (
    <div ref={wrapRef} className={bare ? `${styles.wrap} ${styles.wrapBare}` : styles.wrap}>
      {newBelow && (
        <button type="button" className={styles.newPill} onClick={toBottom}>
          New messages <Icon name="arrow.down" size={10} />
        </button>
      )}
      <div ref={scrollRef} onScroll={onScroll} className={narrow ? `${styles.thread} ${styles.threadNarrow}` : styles.thread}>
        {hasEarlier && onLoadEarlier && (
          <button type="button" className={styles.loadEarlier} onClick={onLoadEarlier}>Load earlier messages</button>
        )}
        {rows.map(row => row.type === 'sep'
          ? <div key={row.id} data-row-id={row.id} className={styles.separator}><span>{row.label}</span></div>
          : (
            <ChatBubble
              key={row.id}
              bodyHtml={row.bodyHtml}
              isInbound={row.isInbound}
              showAvatar={row.showAvatar}
              time={row.time}
              senderName={row.sender}
              senderLabel={row.senderLabel}
              rowId={row.id}
              onOpenMedia={onOpenMedia}
              avatarSrc={row.avatarSrc}
              isDraft={row.isDraft}
              pending={row.pending}
              attachments={row.attachments}
              reaction={row.reaction}
              deleted={row.deleted}
              enriching={row.enriching}
              focused={row.index === focusedMsgIndex}
            />
          ))}
      </div>
    </div>
  )
}
