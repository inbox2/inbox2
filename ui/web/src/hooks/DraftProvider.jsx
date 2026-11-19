import { useState, useCallback, useRef } from 'react'
import * as Y from 'yjs'
import api from '../lib/api'
import log from '../lib/log'
import { isRealOrgId } from '../lib/org'
import { editorHtmlToEmailHtml } from '../lib/emailHtml'
import { isTauri } from '../lib/tauri'
import { playSwoosh } from '../lib/notificationSound'
import { setLastFrom } from '../lib/lastUsedPref'
import useAccountStore from '../stores/accountStore'
import useFromIdentities from './useFromIdentities'
import YjsActionCableProvider from '../lib/YjsActionCableProvider'
import DraftContext from './DraftContext'

const AUTOSAVE_DELAY = 2000

// Compose-window state of a draft (not conversation status): an open popup vs
// a minimized chip in the DraftBar.
const DRAFT_STATUS = {
  OPEN: 'open',
  MINIMIZED: 'minimized',
}

// Module-level so open composers survive provider remounts: each primary
// screen (AppChrome, InboxPage, UnifiedInboxView) mounts its own DraftProvider,
// and navigating between them must not drop the draft list mid-compose. Only
// one provider is mounted at a time, so a plain handoff cache is enough.
let draftCache = []
const yjsCache = {} // { [draftId]: { doc, provider } }
const saveTimerCache = {}

export default function DraftProvider({ orgId, activeAccountKey, children }) {
  const [drafts, setDraftsState] = useState(draftCache)
  const fromIdentities = useFromIdentities()
  const setDrafts = useCallback((updater) => {
    setDraftsState(prev => {
      draftCache = typeof updater === 'function' ? updater(prev) : updater
      return draftCache
    })
  }, [])
  const saveTimers = useRef(saveTimerCache)
  const yjsRefs = useRef(yjsCache)

  const createYjsDoc = useCallback((draftId, user) => {
    const doc = new Y.Doc()
    const provider = new YjsActionCableProvider(doc, draftId, { user, syncOnJoin: true }) // a (re)joining co-editor gets our full state, not just later edits
    yjsRefs.current[draftId] = { doc, provider }
    return { doc, provider }
  }, [])

  const destroyYjsDoc = useCallback((draftId) => {
    const ref = yjsRefs.current[draftId]
    if (ref) {
      ref.provider.destroy()
      ref.doc.destroy()
      delete yjsRefs.current[draftId]
    }
  }, [])

  const getYjsDoc = useCallback((draftId) => {
    return yjsRefs.current[draftId] || null
  }, [])

  const createDraft = useCallback(async (opts = {}) => {
    const params = {
      from_address: opts.fromAddress || '',
      to_address: opts.toAddress || '',
      cc_address: opts.ccAddress || '',
      subject: opts.subject || '',
      body_plain: opts.bodyPlain || '',
      body_html: opts.bodyHtml || '',
    }
    if (opts.conversationId) {
      params.conversation_id = opts.conversationId
    }

    let draftId
    let serverDraft = null

    const localId = () => `draft_local_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`
    if (!isRealOrgId(orgId)) {
      // No org at all (pure external/offline account) — there's no Rails draft
      // endpoint to call, so skip straight to a local draft instead of POSTing
      // to /orgs/null/drafts. (orgId can be the literal "null"/"undefined" string.)
      draftId = localId()
    } else {
      try {
        const res = await api.createDraft(orgId, params)
        draftId = res.draft.id
        serverDraft = res.draft
      } catch {
        // API unavailable (Tauri standalone / offline) — create local-only draft
        draftId = localId()
        log.warn('Draft', `API unavailable, created local draft ${draftId}`)
      }
    }

    // Yjs collaborative editing is activated on demand via enableCollaboration()
    // Not created by default to avoid WebSocket errors when Action Cable isn't available

    const draft = {
      id: draftId,
      orgId,
      status: DRAFT_STATUS.OPEN,
      fromAddress: serverDraft?.from_address || opts.fromAddress || '',
      toAddress: serverDraft?.to_address || opts.toAddress || '',
      ccAddress: serverDraft?.cc_address || opts.ccAddress || '',
      bccAddress: serverDraft?.bcc_address || '',
      subject: serverDraft?.subject || opts.subject || '',
      bodyHtml: serverDraft?.body_html || opts.bodyHtml || '',
      bodyPlain: serverDraft?.body_plain || opts.bodyPlain || '',
      conversationId: opts.conversationId || null,
      quotedHtml: opts.quotedHtml || '',
      // Replies carry the parent message's local key so the provider send can
      // thread (In-Reply-To/References/threadId hydrated by the engine).
      replyToMessageKey: opts.replyToMessageKey || null,
      // Forward seeds attachments up-front (the file bytes are downloaded before
      // the draft is created), so the draft renders complete in one atomic add —
      // no post-creation addAttachment, which proved unreliable across renders.
      attachments: opts.attachments || [],
      saveStatus: serverDraft ? 'saved' : 'local',
      // Which field to focus when the popup opens: 'body' for reply/reply-all
      // (recipients already filled), 'to' for new messages / forwards.
      focus: opts.focus || 'to',
    }

    setDrafts(prev => [...prev, draft])
    return draft
  }, [orgId])

  const updateDraftLocal = useCallback((draftId, updates) => {
    setDrafts(prev => prev.map(d =>
      d.id === draftId ? { ...d, ...updates } : d
    ))
  }, [])

  const saveDraft = useCallback(async (draftId, fields) => {
    // Local-only drafts skip API persistence
    if (draftId.startsWith('draft_local_')) {
      updateDraftLocal(draftId, { saveStatus: 'local' })
      return
    }
    updateDraftLocal(draftId, { saveStatus: 'saving' })
    try {
      await api.updateDraft(orgId, draftId, fields)
      updateDraftLocal(draftId, { saveStatus: 'saved' })
    } catch (e) {
      log.error('Draft', `Save failed for ${draftId}: ${e?.message || e}`)
      updateDraftLocal(draftId, { saveStatus: 'error' })
    }
  }, [orgId, updateDraftLocal])

  const debouncedSave = useCallback((draftId, fields) => {
    if (saveTimers.current[draftId]) {
      clearTimeout(saveTimers.current[draftId])
    }
    updateDraftLocal(draftId, { saveStatus: 'unsaved' })
    saveTimers.current[draftId] = setTimeout(() => {
      saveDraft(draftId, fields)
      delete saveTimers.current[draftId]
    }, AUTOSAVE_DELAY)
  }, [saveDraft, updateDraftLocal])

  const minimizeDraft = useCallback((draftId) => {
    updateDraftLocal(draftId, { status: DRAFT_STATUS.MINIMIZED })
  }, [updateDraftLocal])

  const restoreDraft = useCallback((draftId) => {
    updateDraftLocal(draftId, { status: DRAFT_STATUS.OPEN })
  }, [updateDraftLocal])

  const closeDraft = useCallback(async (draftId) => {
    // Flush any pending save
    if (saveTimers.current[draftId]) {
      clearTimeout(saveTimers.current[draftId])
      delete saveTimers.current[draftId]
    }
    const draft = drafts.find(d => d.id === draftId)
    if (draft) {
      // The editor's empty state is "<p></p>", so test the text, not the HTML.
      const bodyText = (draft.bodyHtml || '').replace(/<[^>]*>|&nbsp;/g, '').trim() || (draft.bodyPlain || '').trim()
      const hasContent = bodyText || draft.subject || draft.toAddress || draft.attachments?.length
      if (!hasContent && !draftId.startsWith('draft_local_')) {
        // An untouched compose would otherwise linger as a blank thread in every inbox.
        await api.deleteDraft(orgId, draftId).catch(() => { log.warn('Draft', `Failed to drop empty draft: ${draftId}`) })
      } else if (hasContent) {
        await saveDraft(draftId, {
          body_html: draft.bodyHtml,
          body_plain: draft.bodyPlain,
          subject: draft.subject,
          to_address: draft.toAddress,
        }).catch(() => { log.warn('Draft', `Failed to save on close: ${draftId}`) })
      }
    }
    destroyYjsDoc(draftId)
    setDrafts(prev => prev.filter(d => d.id !== draftId))
  }, [drafts, orgId, saveDraft, destroyYjsDoc])

  const deleteDraft = useCallback(async (draftId) => {
    if (saveTimers.current[draftId]) {
      clearTimeout(saveTimers.current[draftId])
      delete saveTimers.current[draftId]
    }
    destroyYjsDoc(draftId)
    if (!draftId.startsWith('draft_local_')) {
      try {
        await api.deleteDraft(orgId, draftId)
      } catch (e) {
        log.warn('Draft', `Delete failed for ${draftId}: ${e?.message || e}`)
      }
    }
    setDrafts(prev => prev.filter(d => d.id !== draftId))
  }, [orgId, destroyYjsDoc])

  const addAttachment = useCallback((draftId, attachment) => {
    setDrafts(prev => prev.map(d =>
      d.id === draftId ? { ...d, attachments: [...d.attachments, attachment] } : d
    ))
  }, [])

  // Patch an existing attachment in place (by key) — used to fill a pending
  // forward placeholder with its downloaded bytes once they arrive.
  const resolveAttachment = useCallback((draftId, attachmentKey, fields) => {
    setDrafts(prev => prev.map(d =>
      d.id === draftId
        ? { ...d, attachments: d.attachments.map(a => a.key === attachmentKey ? { ...a, ...fields } : a) }
        : d
    ))
  }, [])

  const removeAttachment = useCallback((draftId, attachmentKey) => {
    setDrafts(prev => prev.map(d =>
      d.id === draftId ? { ...d, attachments: d.attachments.filter(a => a.key !== attachmentKey) } : d
    ))
  }, [])

  // Route a send to the provider account that owns the From address. Matching
  // the chosen identity is what makes the From picker actually switch accounts;
  // falls back to the active account so existing behavior is unchanged when the
  // From isn't a connected external address. Returns null off-desktop (Rails).
  const providerKeyForFrom = useCallback((fromAddress) => {
    if (!isTauri()) return null
    const accounts = useAccountStore.getState().externalAccounts || []
    const from = (fromAddress || '').toLowerCase()
    const match = accounts.find(a => a.email_address?.toLowerCase() === from)
    if (match) return match.key
    // One of the user's inbox2 addresses goes out through inbox2 (Rails), never
    // the active Gmail/Microsoft channel with a From it can't sign for.
    if (from && fromIdentities.some(i => i.providerType === 'inbox2' && i.email.toLowerCase() === from)) return null
    return activeAccountKey || null
  }, [activeAccountKey, fromIdentities])

  const sendDraft = useCallback(async (draftId) => {
    const draft = drafts.find(d => d.id === draftId)
    if (!draft) return

    log.info('Draft', `Sending draft ${draftId} from=${draft.fromAddress} to=${draft.toAddress} attachments=${draft.attachments.length}`)
    setLastFrom(draft.fromAddress)

    // The editor holds only the user's text; the quoted thread lives separately
    // on the draft (rendered under the rule in the preview). Make the editor
    // HTML email-ready (blank lines + paragraph margins inlined — mail clients
    // reset stylesheet margins), then fold the quote in unsanitized so the
    // original mail's inline styles survive for the recipient. Matches the
    // inline composer's send (Composer.jsx).
    const outgoingHtml = `${editorHtmlToEmailHtml(draft.bodyHtml)}${draft.quotedHtml || ''}`

    let sendResult = null
    const providerKey = providerKeyForFrom(draft.fromAddress)
    // External account (Tauri): send via provider API (Gmail/Microsoft Graph)
    if (providerKey) {
      const { sendMessage } = await import('../lib/providers/index.js')

      // Resolve attachment bytes for the provider send. Offline drafts hold the
      // bytes in memory already (att.data); org-uploaded ones download from S3.
      const attachmentData = []
      for (const att of draft.attachments) {
        try {
          if (att.data) {
            attachmentData.push({
              filename: att.filename,
              mimeType: att.content_type || 'application/octet-stream',
              data: att.data,
            })
            continue
          }
          const url = att.url || att.presigned_url
          if (url) {
            const res = await fetch(url)
            const buffer = await res.arrayBuffer()
            attachmentData.push({
              filename: att.filename,
              mimeType: att.content_type || 'application/octet-stream',
              data: new Uint8Array(buffer),
            })
          }
        } catch (err) {
          log.warn('Draft', `Failed to resolve attachment ${att.filename} for provider send: ${err?.message}`)
        }
      }

      const result = await sendMessage(providerKey, {
        fromAddress: draft.fromAddress,
        toAddress: draft.toAddress,
        ccAddress: draft.ccAddress,
        bccAddress: draft.bccAddress,
        subject: draft.subject,
        bodyHtml: outgoingHtml,
        bodyPlain: draft.bodyPlain,
        attachments: attachmentData,
        replyToMessageKey: draft.replyToMessageKey,
      })
      // The send is durably queued either way; a non-'sent' status means the
      // outbox will retry in the background (e.g. offline). Not a hard error.
      if (result?.status && result.status !== 'sent') {
        log.warn('Draft', `Send queued (${result.status}) for ${draftId}${result.error_message ? `: ${result.error_message}` : ''}`)
      }
      sendResult = result
    } else {
      // Rails API path: send via backend SMTP
      const params = {
        conversation_id: draft.conversationId,
        from_address: draft.fromAddress,
        to_address: draft.toAddress,
        cc_address: draft.ccAddress,
        bcc_address: draft.bccAddress,
        subject: draft.subject,
        body_html: outgoingHtml,
        body_plain: draft.bodyPlain,
        content_type: 'text/html',
      }

      if (draft.attachments.length > 0) {
        // `id` is the att_ key: AttachmentSerializer exposes the public key as
        // `id` (E5), so an API-uploaded attachment has no `key` field at all.
        // Reading only `.key` sent [undefined], the server logged "Attachment
        // not found, skipping", and every attachment on an MX send was silently
        // dropped — the upload succeeded, the mail went out without the file.
        // `a.key` still covers the in-memory/local shape, which has no `id`.
        params.attachment_keys = draft.attachments.map(a => a.id || a.key).filter(Boolean)
      }

      await api.sendMessage(orgId, params)
    }

    log.info('Draft', `Draft ${draftId} sent successfully`)
    playSwoosh()

    destroyYjsDoc(draftId)
    // Local/offline drafts were never persisted server-side; deleting them
    // would hit /orgs/<undefined>/drafts and 401. Only clean up real drafts.
    if (!draftId.startsWith('draft_local_')) {
      try {
        await api.deleteDraft(orgId, draftId)
      } catch {
        // Draft may not need explicit deletion
      }
    }
    setDrafts(prev => prev.filter(d => d.id !== draftId))
    return sendResult
  }, [orgId, providerKeyForFrom, drafts, destroyYjsDoc])

  // Send a reply directly from the inline composer, bypassing the draft popup
  // lifecycle. Same transport as sendDraft (provider for external accounts,
  // Rails API otherwise), minus attachments (escalate to the popup for those).
  const sendInline = useCallback(async ({ conversationId, fromAddress, toAddress, ccAddress = '', subject, bodyHtml, bodyPlain, replyToMessageKey }) => {
    if (!toAddress) return
    log.info('Draft', `Inline send conv=${conversationId} to=${toAddress}`)
    const providerKey = providerKeyForFrom(fromAddress)
    if (providerKey) {
      const { sendMessage } = await import('../lib/providers/index.js')
      const result = await sendMessage(providerKey, {
        fromAddress, toAddress, ccAddress, subject, bodyHtml, bodyPlain, attachments: [], replyToMessageKey,
      })
      playSwoosh()
      return result
    }
    await api.sendMessage(orgId, {
      conversation_id: conversationId,
      from_address: fromAddress,
      to_address: toAddress,
      cc_address: ccAddress,
      subject,
      body_html: bodyHtml,
      body_plain: bodyPlain,
      content_type: 'text/html',
    })
    playSwoosh()
    return null
  }, [orgId, providerKeyForFrom])

  const enableCollaboration = useCallback((draftId, user) => {
    if (!yjsRefs.current[draftId]) {
      createYjsDoc(draftId, user)
    }
  }, [createYjsDoc])

  const openDrafts = drafts.filter(d => d.status === DRAFT_STATUS.OPEN)
  const minimizedDrafts = drafts.filter(d => d.status === DRAFT_STATUS.MINIMIZED)

  return (
    <DraftContext.Provider value={{
      drafts,
      openDrafts,
      minimizedDrafts,
      createDraft,
      updateDraftLocal,
      saveDraft,
      debouncedSave,
      minimizeDraft,
      restoreDraft,
      closeDraft,
      deleteDraft,
      sendDraft,
      sendInline,
      providerKeyForFrom,
      addAttachment,
      resolveAttachment,
      removeAttachment,
      getYjsDoc,
      enableCollaboration,
    }}>
      {children}
    </DraftContext.Provider>
  )
}
