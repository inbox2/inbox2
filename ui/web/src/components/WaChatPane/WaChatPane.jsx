import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import Avatar from '../Avatar'
import ChatThread from '../ChatThread/ChatThread'
import Icon from '../Icon'
import { PROVIDER } from '../../lib/providerTypes'
import layoutStyles from '../../styles/layout.module.css'
import detailStyles from '../ConversationDetail/ConversationDetail.module.css'
import laneStyles from '../ListViewColumns/ListViewColumns.module.css'
import { waMessages, waMediaUrl, useWaStatus, waOpenInWhatsApp } from '../../lib/localWhatsApp'
import WaMediaViewer from '../WaMediaViewer/WaMediaViewer'
import WaComposer from './WaComposer'
import WaErrorDialog from './WaErrorDialog'
import { isDemoMode } from '../../lib/demoData'
import { toChatMessage, mergeNewest } from '../../lib/waMessages'
import styles from './WaChatPane.module.css'

const PAGE = 200

/**
 * One local-WhatsApp chat, read live from WhatsApp Desktop's database:
 * header (the Meta channels' social detail header) + the shared ChatThread,
 * centred at messenger width. Reloads when anything in WhatsApp changes.
 * `anchorId` opens the page around that message (a search hit) and scrolls to
 * it; "Latest" leaves it for the newest page.
 * A reply box acted out in WhatsApp Desktop itself, and a WhatsApp button
 * (whatsapp_actions.rs).
 */
//
// `onClose` makes it a column (the WhatsApp tab): a lane header with the chat's
// name and a ✕, and the thread drawn over the lane's own gradient.
export default function WaChatPane({ chat, anchorId = null, onClose, onRead, dragHandle }) {
  const { version } = useWaStatus()
  // The search hit being shown; null = following the newest messages.
  const [anchor, setAnchor] = useState(anchorId)
  const [page, setPage] = useState({ chatId: null, messages: [], hasEarlier: false })
  const [error, setError] = useState(null)
  // A failed Load earlier: shown above the thread with a retry; the thread stays.
  const [earlierError, setEarlierError] = useState(null)
  // The media viewer's attachment, when one is open.
  const [viewing, setViewing] = useState(null)
  // A failed first load offers a retry (the status poll may not move to re-run it).
  const [retry, setRetry] = useState(0)
  // Open in WhatsApp: busy flag + the last failure, shown as an alert.
  const [acting, setActing] = useState(false)
  const [actionError, setActionError] = useState(null)
  // Sends in flight: shown as bubbles at once, until the real message is read
  // back from WhatsApp's database (then the page carries it).
  const [pending, setPending] = useState([])
  const act = (fn, failed) => {
    setActing(true)
    setActionError(null)
    fn(chat.id).catch(e => setActionError({ title: failed, error: String(e?.message || e) })).finally(() => setActing(false))
  }

  // Load the newest page, or the page around the search hit. A live update
  // re-reads only the newest page and merges it in (new messages appended,
  // edited ones replaced), so everything paged in with Load earlier stays.
  const loaded = page.chatId === chat.id ? page.messages.length : 0
  useEffect(() => {
    // A search hit's page stays put; live updates only follow the newest page.
    if (anchor && loaded) return undefined
    let cancelled = false
    waMessages(chat.id, anchor && !loaded ? { around: anchor, limit: PAGE } : { limit: PAGE })
      .then(res => {
        if (cancelled) return
        setPage(p => (p.chatId === chat.id && p.messages.length
          ? mergeNewest(p, res)
          : { chatId: chat.id, messages: res.messages, hasEarlier: res.has_earlier }))
        setError(null)
      })
      .catch(e => { if (!cancelled) setError(String(e?.message || e)) })
    return () => { cancelled = true }
  // `loaded` is read, not a trigger: paging is loadEarlier's job.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chat.id, anchor, version, retry])

  // Leave the search hit for the newest page (live again from here on).
  const jumpToLatest = useCallback(() => {
    setPage({ chatId: null, messages: [], hasEarlier: false })
    setAnchor(null)
  }, [])

  // One page at a time (a second click while loading would fetch the same page),
  // and never a message twice.
  const paging = useRef(false)
  const loadEarlier = useCallback(() => {
    const first = page.messages[0]
    if (!first || paging.current) return
    paging.current = true
    setEarlierError(null)
    waMessages(chat.id, { before: first.id, limit: PAGE })
      .then(res => setPage(p => {
        if (p.chatId !== chat.id) return p
        const have = new Set(p.messages.map(m => m.id))
        return { ...p, messages: [...res.messages.filter(m => !have.has(m.id)), ...p.messages], hasEarlier: res.has_earlier }
      }))
      .catch(e => setEarlierError(String(e?.message || e)))
      .finally(() => { paging.current = false })
  }, [chat.id, page.messages])

  const messages = useMemo(
    // A 1:1 chat names no sender per message: it's the chat's own name (avatar initials).
    () => (page.chatId === chat.id
      ? page.messages.map(toChatMessage).filter(Boolean).map(m => (chat.is_group ? m : { ...m, from_address: chat.name }))
      : []),
    [page, chat.id, chat.is_group, chat.name],
  )
  // A pending send has landed once an outgoing message like it, from about
  // when it was sent, is on the page. ponytail: landed entries stay in `pending`
  // (filtered here), one per send while the pane is open.
  const shown = useMemo(() => pending.filter(p => !messages.some(m =>
    !m.is_inbound && !m.system && Date.parse(m.created_at) >= p.at - 5000
      && (p.file ? m.attachments?.length > 0 : (m.body_plain || '').trim() === p.text))), [pending, messages])
  const withPending = useMemo(() => [...messages, ...shown.map(p => ({
    id: p.id,
    created_at: new Date(p.at).toISOString(),
    is_inbound: false,
    pending: true,
    body_plain: p.text || '',
    attachments: p.file ? [{ attachmentId: p.id, name: p.file.split('/').pop(), icon: 'paperclip' }] : [],
  }))], [messages, shown])
  const onPending = useCallback((p) => setPending(list => [...list, p]), [])
  // Confirmed: reload now rather than at the next poll. Failed: drop the bubble
  // (the reply box gets the item back).
  // Demo mode sends nothing (lib/localWhatsApp.js), so no real message ever
  // replaces the bubble: it goes once the "send" resolves.
  // A pane opened at a search hit doesn't follow new messages: a send there
  // moves it to the newest page, where the sent message loads.
  const onSettled = useCallback((id, ok) => {
    if (!ok || isDemoMode()) setPending(list => list.filter(p => p.id !== id))
    else if (anchor) jumpToLatest()
    else setRetry(n => n + 1)
  }, [anchor, jumpToLatest])

  const conversation = useMemo(() => ({
    id: `wa-chat-${chat.id}`,
    providerType: PROVIDER.WHATSAPP,
    channel: PROVIDER.WHATSAPP,
    from_avatar: chat.is_group ? null : waMediaUrl(chat.avatar),
    messages: withPending,
  }), [chat.id, chat.is_group, chat.avatar, withPending])

  // ChatThread's focus index counts bubbles only (system rows aren't bubbles).
  // A hit can be a group event (a system row, not a bubble): scroll by row id too.
  const scrollToId = anchor ? `wa-${anchor}` : null
  const focusedMsgIndex = anchor
    ? messages.filter(m => !m.system).findIndex(m => m.waId === anchor)
    : -1

  const latest = anchor && (
    <button type="button" className={styles.latest} onClick={jumpToLatest}>
      <Icon name="arrow.down" size={10} /> Latest
    </button>
  )
  const tools = (
    <>
      {/* Green while the chat has unread messages: showing it in WhatsApp reads it there. */}
      <button
        type="button"
        className={`${styles.latest}${chat.unread !== 0 ? ` ${styles.unreadPill}` : ''}`}
        onClick={() => act(id => waOpenInWhatsApp(id).then(() => { if (chat.unread !== 0) onRead?.(chat) }), "Couldn't open WhatsApp")}
        disabled={acting}
        title={chat.unread !== 0 ? 'Unread: open in WhatsApp to read it (jumps to the latest message)' : 'Show this chat in WhatsApp'}
      >
        {chat.unread !== 0
          ? <Icon name="checkmark.circle.fill" size={10} className={styles.unreadCheck} />
          : <Icon name="arrow.up.right" size={10} />} WhatsApp
      </button>
    </>
  )
  const actionAlert = (
    <WaErrorDialog error={actionError?.error} title={actionError?.title} onClose={() => setActionError(null)} />
  )
  // Once this chat's page has loaded, empty too (a first message can be sent).
  const composer = page.chatId === chat.id && <WaComposer chat={chat} onPending={onPending} onSettled={onSettled} />

  // A failed refresh with messages already on screen keeps them: the next poll retries.
  const body = error && !loaded
    ? (
      <div className={styles.error} role="alert">
        <span>Couldn't load this chat: {error}</span>
        <button type="button" className={styles.latest} onClick={() => { setError(null); setRetry(n => n + 1) }}>Try again</button>
      </div>
    )
    : !loaded && page.chatId !== chat.id
      ? <div className={styles.error}>Loading…</div>
    // Keyed by the anchor: "Latest" remounts the thread, which opens at the bottom
    // (instead of reading the swap as one new message below the old page).
    : <>
      {earlierError && (
        <div className={styles.inlineError} role="alert">
          Couldn't load earlier messages: {earlierError}
          <button type="button" className={styles.latest} onClick={loadEarlier}>Try again</button>
        </div>
      )}
      <ChatThread key={anchor || 'latest'} conversation={conversation} focusedMsgIndex={focusedMsgIndex} scrollToId={scrollToId} hasEarlier={page.hasEarlier} onLoadEarlier={loadEarlier} narrow={!onClose} bare={!!onClose} onOpenMedia={setViewing} />
    </>

  const viewer = viewing && (
    <WaMediaViewer chatId={chat.id} chatName={chat.name} item={viewing} onClose={() => setViewing(null)} />
  )

  if (onClose) {
    return (
      <div className={styles.pane}>
        {viewer}
        {/* `dragHandle`: hold the header, then drag, to reorder the columns (WhatsAppPage). */}
        <div className={`${laneStyles.columnHeader} ${styles.columnHeader}`} {...dragHandle}>
          <Avatar name={chat.name} src={waMediaUrl(chat.avatar)} size={22} />
          <span className={styles.columnName} dir="auto" title={chat.name}>{chat.name}</span>
          {latest}
          {tools}
          <button type="button" className={styles.close} onClick={onClose} aria-label={`Close ${chat.name}`} title="Close">
            <Icon name="xmark" size={10} />
          </button>
        </div>
        {actionAlert}
        {body}
        {composer}
      </div>
    )
  }

  return (
    <div className={styles.pane}>
      {viewer}
      <div className={`${layoutStyles.detailHeader} ${detailStyles.socialChrome}`}>
        <div className={styles.title}>
          <Avatar name={chat.name} src={waMediaUrl(chat.avatar)} size={24} />
          <h1 className={layoutStyles.detailSubject} dir="auto">{chat.name}</h1>
        </div>
        <div className={styles.actions}>
          {latest}
          {tools}
        </div>
      </div>
      {actionAlert}
      {body}
      {composer}
    </div>
  )
}
