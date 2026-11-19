import { getDb } from '../../lib/db.js';
import { useState, useRef, useEffect, useCallback, useContext, lazy, Suspense } from 'react'
import { AuthContext } from '../../hooks/AuthProvider'
import { useNavigate } from 'react-router'
import Avatar from '../Avatar'
import Tooltip from '../Tooltip'
import AIBadge from '../AIBadge'
import MessageActions from '../MessageActions'
import MessageDetails from '../MessageDetails'
import OpenTrackingBadge from '../OpenTrackingBadge/OpenTrackingBadge'
import LinkClicksBadge from '../OpenTrackingBadge/LinkClicksBadge'
import ViewSourceModal from '../ViewSourceModal'
import CreateRulePopup from '../CreateRulePopup'
import QuotedText from './QuotedText'
import EmailFrame from './EmailFrame'
import MeetingInvite from '../MeetingInvite/MeetingInvite'
import MeetingRequestBanner from '../MeetingInvite/MeetingRequestBanner'
import relativeTime from '../../lib/relativeTime'
import { emailOnly, parseAddress, replyFromAddress } from '../../lib/emailAddress'
import useFromIdentities from '../../hooks/useFromIdentities'
import { triageBadge, priorityChip, isBuiltinTriageLabel } from '../../lib/triage'
import useTriageLabels, { LOCAL_TRIAGE_LABELS } from '../../hooks/useTriageLabels'
import useDrafts from '../../hooks/useDrafts'
import { resolveAccountKey, forwardAttachmentPlaceholder, mxForwardPlaceholder } from '../../lib/draftAttachments'
import { isMxAttachment } from '../../lib/mxAttachments'
import { PROVIDER } from '../../lib/providerTypes'
import { prepareFile, dragFile } from '../../lib/dragOut'
import { isTauri } from '../../lib/tauri'
import { isDemoMode } from '../../lib/demoData'
import log from '../../lib/log'
import api from '../../lib/api'
import { isRealOrgId } from '../../lib/org'
import { paletteSolid } from '../../lib/spaceColors'
import { useAIClassification } from '../../lib/ai/useAIClassification'
import { stripHtml } from '../../lib/messageText'
import { CONV_ACTION, messageActionMenuItems } from '../../lib/conversationActions'
import { CONV_STATUS } from '../../lib/conversationStatus'
import useNavigationStore from '../../stores/navigationStore'
import { openLink } from '../../lib/openLink'
import AddressContextMenu from '../DropdownMenu/AddressContextMenu'
import styles from './MessageCard.module.css'

// Intercept clicks on links inside the email body so they don't navigate the
// whole app webview away. Routes through openLink (in-app browser tab vs system
// browser per the user's setting; ⌘/Ctrl-click always opens externally).
// Spam conversations get links blocked entirely (phishing protection).
function handleBodyLinkClick(e, blocked) {
  const anchor = e.target?.closest?.('a[href]');
  if (!anchor) return;
  const href = anchor.getAttribute('href');
  if (!href) return;
  e.preventDefault();
  if (blocked) return;
  openLink(href, { forceExternal: e.metaKey || e.ctrlKey });
}

// MX mail has no provider account behind it — its attachments stream from the
// org's own API. Everything else (Gmail/Outlook/IMAP) goes through the engine.
async function downloadAttachmentForMessage(attachment, message) {
  if (isMxAttachment(attachment)) {
    const { openMxAttachment } = await import('../../lib/mxAttachments')
    return openMxAttachment(attachment, message)
  }
  const accountKey = await resolveAccountKey(message)
  if (!accountKey) throw new Error('No account key found')
  // downloadAttachment already opens from cache first, then downloads on a miss.
  const { downloadAttachment } = await import('../../lib/providers/index.js')
  await downloadAttachment(accountKey, message.key || message.id, attachment)
}

async function saveAttachmentForMessage(attachment, message) {
  if (isMxAttachment(attachment)) {
    const { saveMxAttachmentAs } = await import('../../lib/mxAttachments')
    return saveMxAttachmentAs(attachment, message)
  }
  const accountKey = await resolveAccountKey(message)
  if (!accountKey) throw new Error('No account key found')
  const { saveAttachmentAs } = await import('../../lib/providers/index.js')
  await saveAttachmentAs(accountKey, message.key || message.id, attachment)
}

// Disk's folder picker, loaded only when someone saves an attachment to Disk.
const DiskPicker = lazy(() => import('../../pages/disk/DiskDialogs').then((m) => ({ default: m.DiskPicker })))

async function handleViewSource(messageKey) {
  const { getMessageSource } = await import('../../lib/providers/index.js')
  // Resolve account key
  const db = await getDb()
  const rows = await db.select(
    'SELECT account_key FROM message_provider_state WHERE message_key = ? LIMIT 1',
    [messageKey]
  )
  const accountKey = rows[0]?.account_key
  if (!accountKey) {
    // No provider state — try local fallback
    return getMessageSource(null, messageKey)
  }
  return getMessageSource(accountKey, messageKey)
}

export default function MessageCard({ sender, email, time, body, isHtml, attachments, message, orgId, conversationId, conversation, defaultFrom, onAction, onConversationAction, folderRole, executePriority, manualTriage, unread, defaultCollapsed, focused, onFocusCard, enriching, showTriage }) {
  const [collapsed, setCollapsed] = useState(defaultCollapsed ?? false)
  const cardRef = useRef(null)
  const senderRef = useRef(null)
  const navigate = useNavigate()
  const { createDraft } = useDrafts()
  // Save to Disk (spec F9): the org's Disk, whichever account the mail came in on.
  const diskOrgId = useContext(AuthContext)?.currentOrg?.id  // context, not useAuth: mail renders outside the provider in stories
  const [diskSave, setDiskSave] = useState(null) // the attachment being saved
  const [exportNote, setExportNote] = useState(null) // Export as .eml: saved / failed
  const [diskNote, setDiskNote] = useState(null)
  const saveToDisk = (parentId) => {
    const attachment = diskSave
    setDiskSave(null)
    setDiskNote(`Saving ${attachment.name} to Disk...`)
    import('../../lib/disk/mail')
      .then(({ saveAttachmentToDisk }) => saveAttachmentToDisk({ orgId: diskOrgId, message, attachment, parentId }))
      .then((how) => setDiskNote(how === 'saved' ? `Saved ${attachment.name} to Disk.` : `Uploading ${attachment.name} to Disk; see the upload panel in Disk.`))
      .catch((e) => setDiskNote(`Could not save ${attachment.name} to Disk: ${e.message}`))
  }
  // Forwarding an attachment sends from the address this message came in on.
  const forwardFrom = replyFromAddress(message, useFromIdentities(), defaultFrom)

  // Right-click an attachment → "Forward": open a blank compose carrying just
  // this one file as a pending placeholder (instant); ComposePopup downloads the
  // bytes (cached) and blocks Send until it lands.
  const handleAttachmentForward = useCallback(async (attachment) => {
    try {
      if (isMxAttachment(attachment)) {
        // The composer owns resolution: only it knows whether this draft sends by
        // uploaded key (MX) or by inline bytes (a provider From).
        createDraft({ fromAddress: forwardFrom, focus: 'to', attachments: [mxForwardPlaceholder(attachment, message)] })
        return
      }
      const accountKey = await resolveAccountKey(message)
      const att = forwardAttachmentPlaceholder(accountKey, message.key || message.id, attachment)
      createDraft({ fromAddress: forwardFrom, focus: 'to', attachments: [att] })
    } catch (e) {
      log.warn('Attachment', `forward failed for ${attachment?.name}: ${e?.message || e}`)
    }
  }, [message, forwardFrom, createDraft])

  const handleViewSender = useCallback((senderEmail) => {
    const url = useNavigationStore.getState().buildUrl({ conversationId: null, _clearFilters: true })
    const sep = url.includes('?') ? '&' : '?'
    navigate(`${url}${sep}from=${encodeURIComponent(senderEmail)}`)
  }, [navigate])

  // Scroll into view when focused via keyboard
  useEffect(() => {
    if (focused && cardRef.current) {
      cardRef.current.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    }
  }, [focused])
  const [showDetails, setShowDetails] = useState(false)
  const [sourceOpen, setSourceOpen] = useState(false)
  const [sourceData, setSourceData] = useState(null)
  const [sourceLoading, setSourceLoading] = useState(false)
  const [createRuleOpen, setCreateRuleOpen] = useState(false)

  const plainText = stripHtml(body)
  const { sentiment, intent } = useAIClassification(message?.id || null, plainText, message)

  // Local-channel rows come from SQLite and carry `key`; MX (API) rows never do
  // (their public id is `id` only). Both carry triage_label/triage_priority.
  const isLocalConv = !!conversation?.key

  // Spam threads (wherever opened from — folder view or search) get body links
  // disabled: clicks are swallowed instead of routed to openLink.
  const linksBlocked = conversation?.status === CONV_STATUS.SPAM

  const date = new Date(time)
  const fullDate = date.toLocaleString()
  const relative = relativeTime(date)
  // The conversation-level classification chip (shown on the newest card only,
  // next to the time — the list rows stay clean of it).
  // A custom label's name comes from its list: the engine's for local rows, the
  // org's for MX rows. Built-ins need no lookup, so nothing loads for them.
  const triageLabel = showTriage ? conversation?.triage_label : null
  const labelSource = triageLabel && !isBuiltinTriageLabel(triageLabel)
    ? (isLocalConv ? LOCAL_TRIAGE_LABELS : (isRealOrgId(orgId) ? orgId : null))
    : null
  const { labels: triageLabels } = useTriageLabels(labelSource)
  const triage = triageBadge(triageLabel, triageLabels)
  const priority = showTriage ? priorityChip(conversation?.triage_priority) : null

  // Drag out of the window (desktop): an attachment chip as its own file once it
  // is on this Mac (opened before). Hover only looks it up; nothing downloads.
  // A chip that isn't there yet refuses the drag (and shakes).
  const messageKey = message?.key || message?.id
  // MX by the thread's own provider (orgId also names the workspace a local
  // channel's mail is shown in); a thread without one falls back to the route.
  const isMx = conversation?.providerType
    ? conversation.providerType === PROVIDER.INBOX2
    : isRealOrgId(orgId) && !!conversationId
  // Not in demo mode: the dragged file would be the real attachment.
  const canDrag = isTauri() && !isDemoMode() && !!messageKey && !message?.is_draft
  const attachmentDragKey = (a) => `att:${messageKey}:${a.attachmentId || a.mxKey || a.name}`
  const prepareAttachmentDrag = useCallback((a) => {
    prepareFile(attachmentDragKey(a), () => import('../../lib/mailDrag').then(({ cachedAttachmentFile }) => cachedAttachmentFile(a, message)))
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [message, messageKey])
  const dragAttachment = useCallback((e, a) => dragFile(e, attachmentDragKey(a)), [messageKey]) // eslint-disable-line react-hooks/exhaustive-deps
  // The message as a .eml (local: the provider's raw source; MX: built from it).
  function exportEml() {
    setExportNote(null)
    return import('../../lib/mailDrag')
      .then(({ exportEml: save }) => save(message, { mx: isMx, attachments }))
      .then((saved) => { if (saved) setExportNote(`Saved ${saved.split('/').pop()}`) })
      .catch((e) => {
        log.warn('MessageCard', `export .eml failed: ${e?.message || e}`)
        setExportNote(`Couldn't export this email: ${e?.message || e}`)
      })
  }

  const openSource = () => {
    setSourceOpen(true)
    if (!sourceData && message?.id) {
      setSourceLoading(true)
      if (isRealOrgId(orgId) && conversationId) {
        api.getMessageRaw(orgId, conversationId, message.id)
          .then(data => setSourceData(data))
          .catch(() => setSourceData({ error: 'Couldn’t load the message source' }))
          .finally(() => setSourceLoading(false))
      } else {
        handleViewSource(message.key || message.id)
          .then(data => setSourceData(data))
          .catch(() => setSourceData({ error: 'Couldn’t load the message source' }))
          .finally(() => setSourceLoading(false))
      }
    }
  }

  // Built fresh each render (deliberately not memoized): the menu callbacks
  // close over onAction/onConversationAction/executePriority, which parents pass
  // as new inline arrows every render — a narrow-dep memo here captured stale
  // ones. The array is tiny and MessageActions only renders items when opened,
  // so there's nothing to memoize away.
  const menuItems = messageActionMenuItems(conversation, {
    onReply: () => onAction?.('reply'),
    onReplyAll: () => onAction?.('reply-all'),
    onForward: () => onAction?.('forward'),
    onDetails: () => setShowDetails(v => !v),
    onSource: openSource,
    // A sealed message exports only once opened: until then it is a placeholder
    // (empty body, redacted addresses), and the .eml would be one too.
    onExportEml: messageKey && !message?.is_draft && (!message?.sealed || message?.sealedDecrypted) ? exportEml : undefined,
    onMarkReadUnread: () => onConversationAction?.(conversation?.read ? CONV_ACTION.MARK_UNREAD : CONV_ACTION.MARK_READ),
    onArchive: () => onConversationAction?.(CONV_ACTION.ARCHIVE),
    onSpam: () => onConversationAction?.(CONV_ACTION.SPAM),
    onTrash: () => onConversationAction?.(CONV_ACTION.TRASH),
    onMoveToInbox: () => onConversationAction?.(CONV_ACTION.MOVE_TO_INBOX),
    folderRole,
    executePriority: executePriority || (() => {}),
    detailsOpen: showDetails,
    onCreateRule: () => setCreateRuleOpen(true),
    manualTriage,
  })

  const toggleCollapsed = () => {
    setCollapsed(v => {
      if (v && cardRef.current) {
        requestAnimationFrame(() => cardRef.current.scrollIntoView({ block: 'start', behavior: 'smooth' }));
      }
      return !v;
    });
  };

  const cardCls = [styles.card]
  if (unread) cardCls.push(styles.unread)
  if (collapsed) cardCls.push(styles.collapsed)
  if (focused) cardCls.push(styles.focused)

  return (
    <>
      <div ref={cardRef} className={cardCls.join(' ')} data-message-card role="presentation" onMouseDown={() => onFocusCard?.()}>
        <div
          className={styles.header}
          role="button"
          tabIndex={0}
          aria-expanded={!collapsed}
          onClick={toggleCollapsed}
          onKeyDown={(e) => {
            if (e.target !== e.currentTarget) return;
            if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleCollapsed(); }
            // The sender's copy menu, from the keyboard: it is not a tab stop of its own
            // (a button inside this button), so the header raises it.
            if (e.key === 'ContextMenu' || (e.shiftKey && e.key === 'F10')) {
              e.preventDefault();
              senderRef.current?.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true }));
            }
          }}
        >
          <Avatar name={sender} email={email} src={conversation?.from_avatar || undefined} size={28} unread={unread} loading={enriching} />
          <AddressContextMenu email={email} name={parseAddress(message?.from_address).explicit ? sender : ''}>
            <div ref={senderRef}>
              <div className={styles.sender} dir="auto">{sender}</div>
              <div className={styles.email}>{email}</div>
            </div>
          </AddressContextMenu>
          {collapsed && <div className={styles.snippet}>{plainText.slice(0, 120)}{plainText.length > 120 ? '...' : ''}</div>}
          <div className={styles.headerActions} role="presentation" onClick={(e) => e.stopPropagation()}>
            {message?.is_draft ? <span className={styles.draftBadge}>Draft</span> : null}
            {sentiment?.label && <AIBadge type="sentiment" label={sentiment.label} score={sentiment.score} />}
            {intent?.label && <AIBadge type="intent" label={intent.label} score={intent.score} />}
            {priority && (
              <span className={`${styles.triageBadge} ${styles[`triage_${priority.tone}`] || ''}`}>
                {priority.badge}
              </span>
            )}
            {triage && (
              <span
                className={`${styles.triageBadge} ${styles[`triage_${triage.tone}`] || ''}`}
                ref={triage.color ? (el) => { if (el) el.style.setProperty('--label-color', paletteSolid(triage.color) || 'currentColor') } : undefined}
                data-colored={triage.color ? '' : undefined}
              >
                {triage.badge}
              </span>
            )}
            <OpenTrackingBadge message={message} />
            <LinkClicksBadge message={message} />
            <Tooltip content={fullDate}>
              <span className={styles.time}>{relative}</span>
            </Tooltip>
            <MessageActions items={menuItems} />
          </div>
        </div>
        {!collapsed && (
          <>
            <MeetingRequestBanner message={message} orgId={orgId} />
            <MeetingInvite
              message={message}
              attachments={attachments}
              orgId={orgId}
              // Answering an invite is done with the mail: from the inbox it archives (Gmail's
              // RSVP); in archive/sent/trash/spam it stays put.
              onAnswered={folderRole ? undefined : () => onConversationAction?.(CONV_ACTION.ARCHIVE)}
            />
            <MessageDetails
              message={message}
              expanded={showDetails}
              attachments={attachments}
              onAttachmentClick={(a) => downloadAttachmentForMessage(a, message)}
              onAttachmentForward={handleAttachmentForward}
              onAttachmentSaveAs={(a) => saveAttachmentForMessage(a, message)}
              onAttachmentSaveToDisk={diskOrgId ? setDiskSave : undefined}
              onAttachmentPrepareDrag={canDrag ? prepareAttachmentDrag : undefined}
              onAttachmentDragOut={canDrag ? dragAttachment : undefined}
              onViewSender={handleViewSender}
            />
            {diskNote && <p className={styles.diskNote} role="status">{diskNote}</p>}
            {exportNote && <p className={styles.diskNote} role="status">{exportNote}</p>}
            {diskSave && (
              <Suspense fallback={null}>
                <DiskPicker orgId={diskOrgId} verb="Save" onClose={() => setDiskSave(null)} onPick={saveToDisk} />
              </Suspense>
            )}
            {isHtml ? (
              // HTML email → isolated iframe (own <style>/layout, blocked + proxied
              // images, link interception, quote collapsing all handled inside).
              <EmailFrame html={body} sender={email} messageKey={message?.key || message?.id} blockLinks={linksBlocked} />
            ) : (
              // Plain-text email (converted to simple HTML) → no remote images, so
              // render inline and keep the app's dark-theme color adaptation.
              <div
                className={styles.body}
                onClickCapture={(e) => handleBodyLinkClick(e, linksBlocked)}
                // Middle-click fires auxclick (not click) and opens a tab natively —
                // swallow it too when links are blocked. (Inside EmailFrame the
                // sandbox has no allow-popups, so middle-click is already inert.)
                onAuxClickCapture={linksBlocked ? (e) => handleBodyLinkClick(e, true) : undefined}
              >
                <QuotedText html={body} />
              </div>
            )}
          </>
        )}
      </div>
      <ViewSourceModal
        open={sourceOpen}
        source={sourceData}
        loading={sourceLoading}
        onClose={() => setSourceOpen(false)}
      />
      <CreateRulePopup
        open={createRuleOpen}
        onClose={() => setCreateRuleOpen(false)}
        prefill={{
          from: email,
          to: emailOnly(message?.to_address || conversation?.to_address),
          subject: conversation?.subject,
          hasAttachment: (attachments?.length || 0) > 0,
        }}
        // MX-hosted conversation → server-side rules over the API; otherwise the
        // local external-channel rules (Tauri). Keyed off the real org id.
        mx={isRealOrgId(orgId) ? { orgId } : undefined}
      />
    </>
  )
}
