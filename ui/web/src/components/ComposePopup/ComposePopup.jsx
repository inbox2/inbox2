import { lazy, Suspense, useState, useEffect, useCallback, useContext, useRef } from 'react'
import useDrafts from '../../hooks/useDrafts'
import { AuthContext } from '../../hooks/AuthProvider'
import useFromIdentities from '../../hooks/useFromIdentities'
import api from '../../lib/api'
import log from '../../lib/log'
// Lazy: RichEditor pulls the whole TipTap/ProseMirror/Yjs stack — splitting it
// keeps the editor out of the entry chunk (composing is never first paint).
const RichEditor = lazy(() => import('../RichEditor'))
// Disk's file picker, loaded only when the composer attaches or links from Disk.
const DiskPicker = lazy(() => import('../../pages/disk/DiskDialogs').then((m) => ({ default: m.DiskPicker })))
import FileIcon from '../FileIcon'
import formatBytes from '../../lib/formatBytes'
import PreviewPane from '../PreviewPane'
import { editorHtmlToEmailHtml } from '../../lib/emailHtml'
import { useSignatures, signatureFor, applySignature } from '../../lib/signatures'
import ConfirmDialog from '../ConfirmDialog'
import { mayLinkInstead } from '../../lib/disk/mail'
import { ToolbarButton } from '../ToolbarGroup'
import ComposeHeader from './ComposeHeader'
import ComposeFooter from './ComposeFooter'
import SyncProgressBar from '../SyncProgressBar/SyncProgressBar'
import Checkbox from '../Checkbox/Checkbox'
import { COMPOSE_PREVIEW } from '../../lib/storageKeys'
import { registerUnsaved } from '../../lib/unsavedWork'
import styles from './ComposePopup.module.css'

// Persisted compose-popup size (width/height in px), retained across sessions —
// separately per preview mode, since the popup is deliberately narrower without
// the preview pane.
const COMPOSE_SIZE_KEY = 'compose-popup-size'
const sizeKey = (showPreview) => showPreview ? COMPOSE_SIZE_KEY : `${COMPOSE_SIZE_KEY}-nopreview`
const DEFAULT_SIZE = { true: { w: '60vw', h: '80vh' }, false: { w: '740px', h: '80vh' } }

// Bytes of one draft attachment: an API attachment carries size_bytes, a local one its data.
const attachmentBytes = (a) => a.size_bytes ?? a.size ?? a.data?.length ?? 0

function tooBigMessage(tooBig) {
  if (!tooBig) return ''
  const limit = formatBytes(tooBig.limitBytes)
  if (tooBig.node) return `${tooBig.node.name} makes this mail larger than ${limit}. Anyone with the Disk link can open it.`
  const names = tooBig.files.map((f) => f.name)
  const what = names.length === 1 ? names[0] : `${names.length} files`
  return `${what} ${names.length === 1 ? 'makes' : 'make'} this mail larger than ${limit}. Anyone with the link can open the ${names.length === 1 ? 'copy' : 'copies'} on your Disk.`
}

export default function ComposePopup({ draft, index = 0 }) {
  const {
    updateDraftLocal,
    debouncedSave,
    minimizeDraft,
    closeDraft,
    deleteDraft,
    sendDraft,
    providerKeyForFrom,
    addAttachment,
    resolveAttachment,
    removeAttachment,
    getYjsDoc,
  } = useDrafts()

  const fromIdentities = useFromIdentities()
  // Preview shows the email-ready transform of the editor HTML (blank lines
  // and paragraph margins inlined) — the same transform the send applies.
  const [previewHtml, setPreviewHtml] = useState(() => editorHtmlToEmailHtml(draft.bodyHtml))
  const [showPreview, setShowPreview] = useState(() => localStorage.getItem(COMPOSE_PREVIEW) === 'true')
  const [confirmDiscard, setConfirmDiscard] = useState(false)
  // Escape / ✕ on an edited draft asks first. A Gmail/Outlook-account draft
  // (draft_local_) lives only in memory, so closing it loses the text; an
  // inbox2 draft is saved and stays in Drafts.
  const [confirmClose, setConfirmClose] = useState(false)
  const isLocalDraft = draft.id.startsWith('draft_local_')
  const [uploading, setUploading] = useState(false)
  // From Disk (spec F9): 'attach' | 'link' while the picker is open. tooBig offers a link instead of
  // an attachment: { node, limitBytes } for a Disk file, { files, limitBytes } for files from the computer.
  const auth = useContext(AuthContext)  // context, not useAuth: mail renders outside the provider in stories
  // The draft's own organization: Disk files and links belong to the org the mail goes out from.
  const diskOrg = auth?.organizations?.find(o => o.id === draft.orgId) || auth?.currentOrg
  const diskOrgId = diskOrg?.id
  // What one mail's attachments may add up to before the send is refused (the API's number, 25 MB).
  const sendCap = diskOrg?.send_attachment_limit_bytes
  // A sealed domain never gets the "send a link instead" offer: a public link to a readable file undoes the sealing.
  const linkAllowed = !!diskOrg?.plan?.disk && mayLinkInstead({
    domains: diskOrg.domains, fromAddress: draft.fromAddress || '', viaProvider: !!providerKeyForFrom(draft.fromAddress),
  })
  const [diskPick, setDiskPick] = useState(null)
  const [tooBig, setTooBig] = useState(null)
  const [editor, setEditor] = useState(null)
  const [sending, setSending] = useState(false)
  const [sendError, setSendError] = useState(null)
  const popupRef = useRef(null)
  const fileInputRef = useRef(null)
  const dirtyRef = useRef(false) // any user edit (body, fields, attachments)
  // An edited, unsent message: offered to copy if the session ends (SignedOutScreen).
  useEffect(() => (editor ? registerUnsaved(`Message: ${draft.subject || 'no subject'}`, () => (dirtyRef.current ? editor.getText() : '')) : undefined), [editor, draft.subject])

  // Get Yjs doc and provider for collaborative editing
  const yjsRef = getYjsDoc(draft.id)

  // Resolve pending forward attachments: download their bytes (cached) here in
  // the composer — the rendering provider — so the update reliably lands on the
  // draft. The chip shows a spinner while pending; Send is blocked until done.
  // A real Rails draft with an org From uploads attachments to the API's S3 store
  // and sends by key; a provider-account From (or a local draft id, which would
  // 404 the upload) keeps the bytes in memory for the provider send.
  const apiUploadFor = useCallback((d) =>
    !!d.orgId && !d.id.startsWith('draft_local_') && !providerKeyForFrom(d.fromAddress),
  [providerKeyForFrom])

  const pendingDownloadsRef = useRef(new Set())
  const hasPendingAttachments = draft.attachments.some(a => a.pending)
  useEffect(() => {
    for (const att of draft.attachments) {
      if (!att.pending || pendingDownloadsRef.current.has(att.key)) continue

      // Forwarding an MX attachment: no provider to pull from — stream the bytes
      // from our own API. An MX draft sends by attachment KEY, so the bytes have
      // to be re-uploaded to get a row of their own; a provider-account From
      // sends the bytes inline and can keep them in memory.
      if (att.mxForward) {
        pendingDownloadsRef.current.add(att.key)
        import('../../lib/mxAttachments')
          .then(({ mxAttachmentBytes }) => mxAttachmentBytes(att.mxForward.attachment, att.mxForward.message))
          .then(async (data) => {
            if (!apiUploadFor(draft)) {
              return resolveAttachment(draft.id, att.key,
                { data, size: data.length, pending: false, mxForward: undefined })
            }
            const formData = new FormData()
            formData.append('file', new File([data], att.filename, { type: att.content_type }))
            formData.append('message_id', draft.id)
            const res = await api.upload(`/orgs/${draft.orgId}/attachments`, formData)
            resolveAttachment(draft.id, att.key,
              { ...res.attachment, key: res.attachment.id, size: data.length, pending: false, mxForward: undefined })
          })
          .catch((e) => {
            log.warn('Compose', `forward attachment ${att.filename} failed: ${e?.message || e}`)
            resolveAttachment(draft.id, att.key, { pending: false, failed: true, mxForward: undefined })
          })
          .finally(() => pendingDownloadsRef.current.delete(att.key))
        continue
      }

      if (!att.download) continue
      pendingDownloadsRef.current.add(att.key)
      const { accountKey, messageKey, attachmentId } = att.download
      import('../../lib/providers/index.js')
        // Pass the filename too — it keys the on-disk cache, so this shares the
        // exact file Open/Save-as cached (instant, even across restarts).
        .then(({ downloadAttachmentBytes }) => downloadAttachmentBytes(accountKey, messageKey, { attachmentId, name: att.filename }))
        .then((data) => resolveAttachment(draft.id, att.key, { data, size: data.length, pending: false, download: undefined }))
        .catch((e) => {
          log.warn('Compose', `forward attachment ${att.filename} download failed: ${e?.message || e}`)
          resolveAttachment(draft.id, att.key, { pending: false, failed: true, download: undefined })
        })
        .finally(() => pendingDownloadsRef.current.delete(att.key))
    }
  }, [draft.attachments, draft.id, draft.orgId, resolveAttachment, apiUploadFor])

  // Offset multiple popups so they don't fully overlap
  useEffect(() => {
    if (popupRef.current) {
      const offset = index * 30
      popupRef.current.style.setProperty('--compose-offset-x', `${offset}px`)
      popupRef.current.style.setProperty('--compose-offset-y', `${offset}px`)
    }
  }, [index])

  // Restore the user's last-chosen popup size for the current preview mode
  // (persisted across sessions), falling back to that mode's default.
  useEffect(() => {
    const el = popupRef.current
    if (!el) return
    let saved = null
    try {
      saved = JSON.parse(localStorage.getItem(sizeKey(showPreview)) || 'null')
    } catch { /* ignore malformed storage */ }
    const def = DEFAULT_SIZE[showPreview]
    el.style.setProperty('--compose-width', saved?.w ? `${saved.w}px` : def.w)
    el.style.setProperty('--compose-height', saved?.h ? `${saved.h}px` : def.h)
  }, [showPreview])

  // Drag the top-left handle to resize (the popup is anchored bottom-right, so it
  // grows up-and-left). Writes the live size to CSS vars and persists on release.
  const handleResizeStart = useCallback((e) => {
    e.preventDefault()
    const el = popupRef.current
    if (!el) return
    const rect = el.getBoundingClientRect()
    const startX = e.clientX, startY = e.clientY
    const startW = rect.width, startH = rect.height
    const minW = 480, minH = 400 // matches --compose-min-* tokens
    const maxW = window.innerWidth - 32
    const maxH = window.innerHeight - 32
    const onMove = (ev) => {
      const w = Math.min(maxW, Math.max(minW, startW + (startX - ev.clientX)))
      const h = Math.min(maxH, Math.max(minH, startH + (startY - ev.clientY)))
      el.style.setProperty('--compose-width', `${w}px`)
      el.style.setProperty('--compose-height', `${h}px`)
    }
    const onUp = () => {
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
      const r = el.getBoundingClientRect()
      try {
        localStorage.setItem(sizeKey(showPreview), JSON.stringify({ w: Math.round(r.width), h: Math.round(r.height) }))
      } catch { /* ignore */ }
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
  }, [showPreview])

  // Focus the To field for new messages / forwards; reply/reply-all autofocus
  // the body via RichEditor instead (recipients are already filled).
  useEffect(() => {
    if (draft.focus === 'body') return
    const t = setTimeout(() => {
      popupRef.current
        ?.querySelector('input[placeholder="recipient@example.com"]')
        ?.focus()
    }, 60)
    return () => clearTimeout(t)
  }, [draft.focus])

  // Signatures (spec 8.1.7): the one for the From address goes under the text,
  // and changes with the From. A new message gets it added; a saved draft keeps
  // what it has (its signature still swaps, or goes, with the From).
  const fromOrgId = fromIdentities.find((i) => i.email.toLowerCase() === (draft.fromAddress || '').toLowerCase())?.orgId
  const signatures = useSignatures(fromOrgId || null)
  const signatureLoading = !!fromOrgId && signatures === undefined
  const addSignatureRef = useRef(null) // null until the editor is first seen: then whether it was empty
  const applyingSignatureRef = useRef(false)
  const hadSignatureRef = useRef(false) // the body had a signature when the editor opened
  // Read when the editor opens, before the signatures load or anyone types.
  // A draft that already had a signature gets one back after a From switch.
  useEffect(() => {
    if (editor && addSignatureRef.current === null) {
      hadSignatureRef.current = editor.getHTML().includes('data-signature')
      addSignatureRef.current = editor.isEmpty || !!draft.addSignature || hadSignatureRef.current
    }
  }, [editor, draft.addSignature])
  // The From address the body's signature belongs to (the draft's own when it opened).
  const signedFromRef = useRef(draft.fromAddress)
  useEffect(() => {
    if (!editor || signatures === undefined || !draft.fromAddress) return
    // A saved draft keeps the signature it has until its From address changes.
    if (signedFromRef.current === draft.fromAddress && hadSignatureRef.current) return
    // The fetch failed: keep the draft's own signature, but drop one that belongs
    // to a different From address.
    const sig = signatures === null ? undefined : signatureFor(signatures, draft.fromAddress)
    if (sig === undefined && signedFromRef.current === draft.fromAddress) return
    applyingSignatureRef.current = true
    try { applySignature(editor, sig ?? null, addSignatureRef.current) } finally { applyingSignatureRef.current = false }
    signedFromRef.current = draft.fromAddress
  }, [editor, signatures, draft.fromAddress])

  const handleEditorUpdate = useCallback(({ html, text }) => {
    if (!applyingSignatureRef.current) dirtyRef.current = true
    setPreviewHtml(editorHtmlToEmailHtml(html))
    updateDraftLocal(draft.id, {
      bodyHtml: html,
      bodyPlain: text,
    })
    debouncedSave(draft.id, {
      body_html: html,
      body_plain: text,
    })
  }, [draft.id, updateDraftLocal, debouncedSave])

  const handleFieldChange = useCallback((field, value) => {
    dirtyRef.current = true
    const fieldMap = {
      toAddress: 'to_address',
      ccAddress: 'cc_address',
      bccAddress: 'bcc_address',
      fromAddress: 'from_address',
      subject: 'subject',
    }
    updateDraftLocal(draft.id, { [field]: value })
    debouncedSave(draft.id, { [fieldMap[field]]: value })
  }, [draft.id, updateDraftLocal, debouncedSave])

  // Preselect the first available identity when the draft's From isn't one of
  // them (fresh compose, or a default that doesn't map to a known account), so
  // a real account is always selected rather than showing an empty picker.
  // Done via updateDraftLocal (not handleFieldChange) so it doesn't mark the
  // draft dirty — an untouched scaffold should still discard on Escape.
  useEffect(() => {
    if (fromIdentities.length === 0) return
    const current = (draft.fromAddress || '').toLowerCase()
    if (fromIdentities.some(i => i.email.toLowerCase() === current)) return
    const email = fromIdentities[0].email
    updateDraftLocal(draft.id, { fromAddress: email })
    debouncedSave(draft.id, { from_address: email })
  }, [fromIdentities, draft.fromAddress, draft.id, updateDraftLocal, debouncedSave])

  const handleAttach = useCallback(() => {
    fileInputRef.current?.click()
  }, [])

  // Attach files from the picker or a drop. Route by how the SEND will go
  // (same rule as sendDraft): a provider-account From keeps the bytes in
  // memory for the provider send; only real Rails drafts upload to the API's
  // S3 store (a local draft id would 404 the upload and silently eat the file).
  const attachFiles = useCallback(async (fileList) => {
    const files = Array.from(fileList || [])
    if (files.length === 0) return

    const apiUpload = apiUploadFor(draft)

    // Over the send cap: do not attach what cannot be sent; offer to put it on Disk and link it.
    let total = draft.attachments.reduce((n, a) => n + attachmentBytes(a), 0)
    const over = []
    setUploading(true)
    for (const file of files) {
      if (linkAllowed && sendCap && total + file.size > sendCap) { over.push(file); continue }
      total += file.size
      try {
        if (apiUpload) {
          // Org / Rails-API account: upload to the S3-backed attachment store and
          // send by key. (Requires message_id; re-associated on send.)
          const formData = new FormData()
          formData.append('file', file)
          formData.append('message_id', draft.id)
          log.info('Compose', `Uploading attachment ${file.name} (${file.size} bytes)`)
          const res = await api.upload(`/orgs/${draft.orgId}/attachments`, formData)
          if (res?.attachment) {
            dirtyRef.current = true
            // `key`, not just `id`: the serializer exposes the att_ key as `id`
            // (E5), but every client-side use — the React list key, the chip's
            // remove button, the send's attachment_keys — reads `key`. Without
            // this every uploaded attachment had `key: undefined`, so they
            // collided as React keys and removing one removed all of them.
            addAttachment(draft.id, { ...res.attachment, key: res.attachment.id })
            log.info('Compose', `Attachment uploaded: ${res.attachment.key} ${file.name}`)
          }
        } else {
          // Provider send / local draft: keep the file bytes in memory and hand
          // them straight to the provider send. Never touches the API.
          const buffer = await file.arrayBuffer()
          dirtyRef.current = true
          addAttachment(draft.id, {
            key: `local_${file.name}_${file.size}_${file.lastModified}`,
            filename: file.name,
            content_type: file.type || 'application/octet-stream',
            data: new Uint8Array(buffer),
          })
          log.info('Compose', `Attached local file ${file.name} (${file.size} bytes)`)
        }
      } catch (err) {
        log.error('Compose', `Attachment failed: ${file.name} — ${err?.message || err}`)
        setSendError(`Couldn't attach ${file.name}`)
      }
    }
    setUploading(false)
    if (over.length) setTooBig({ files: over, limitBytes: sendCap })
  }, [draft.id, draft.orgId, draft.fromAddress, draft.attachments, providerKeyForFrom, addAttachment, linkAllowed, sendCap])

  // Send waits for this: a link still on its way would be missing from the mail.
  const whileBusy = async (work) => {
    setUploading(true)
    try { await work() } finally { setUploading(false) }
  }
  const insertDiskLink = async (node) => {
    try {
      const { linkForMail } = await import('../../lib/disk/mail')
      const { url, name } = await linkForMail(diskOrgId, node)
      const a = document.createElement('a')
      a.href = url
      a.textContent = name
      editor?.chain().focus().insertContent(` ${a.outerHTML} `).run()
      dirtyRef.current = true
    } catch (e) {
      setSendError(`Couldn't make a link to ${node.name}: ${e.message}`)
    }
  }
  // Files from the computer that are too big to mail: onto C:\Mail attachments, then a link each.
  const linkInstead = (files) => whileBusy(async () => {
    const { uploadForLink } = await import('../../lib/disk/mail')
    for (const file of files) {
      try {
        await insertDiskLink(await uploadForLink(diskOrgId, file))
      } catch (e) {
        setSendError(`Couldn't upload ${file.name} to Disk: ${e.message}`)
      }
    }
  })
  const pickFromDisk = async (_folderId, node) => {
    const mode = diskPick
    setDiskPick(null)
    if (!node) return
    if (mode === 'link') return whileBusy(() => insertDiskLink(node))
    setUploading(true)
    try {
      const { attachmentFromDisk } = await import('../../lib/disk/mail')
      addAttachment(draft.id, await attachmentFromDisk({ orgId: diskOrgId, draftId: draft.id, apiDraft: apiUploadFor(draft), node }))
      dirtyRef.current = true
    } catch (e) {
      if (e.tooLarge && linkAllowed) setTooBig({ node, limitBytes: e.limitBytes })
      else setSendError(`Couldn't attach ${node.name}: ${e.message}`)
    } finally {
      setUploading(false)
    }
  }

  const handleFileSelected = useCallback(async (e) => {
    await attachFiles(e.target.files)
    // Reset input so same file can be re-selected
    if (fileInputRef.current) fileInputRef.current.value = ''
  }, [attachFiles])

  // Drag & drop a file anywhere on the composer → attach it.
  const handleDragOver = useCallback((e) => {
    if (e.dataTransfer?.types?.includes('Files')) e.preventDefault()
  }, [])
  const handleDrop = useCallback((e) => {
    if (!e.dataTransfer?.files?.length) return
    e.preventDefault()
    e.stopPropagation()
    attachFiles(e.dataTransfer.files)
  }, [attachFiles])

  const handleSend = useCallback(async () => {
    if (sending) return
    // Don't send while a forwarded attachment is still downloading — its bytes
    // aren't on the draft yet (the Send button is disabled too; this guards the
    // ⌘Enter path).
    if (draft.attachments.some(a => a.pending)) {
      setSendError('Attachments are still downloading…')
      return
    }
    if (uploading) {
      setSendError('Wait for the upload to finish.')
      return
    }
    // The new From address's signature is still loading; the old one is in the body.
    if (signatureLoading) return
    // Guard against a doomed send to nobody (provider rejects it 400). A typed
    // recipient is committed on blur, so by here draft.toAddress should be set.
    if (!(draft.toAddress || '').includes('@')) {
      setSendError('Add at least one recipient.')
      return
    }
    setSending(true)
    setSendError(null)
    try {
      // On success sendDraft removes the draft from state and this unmounts,
      // so there's no need to reset `sending`.
      await sendDraft(draft.id)
    } catch (e) {
      log.error('Compose', `Send failed for ${draft.id}: ${e?.message || e}`)
      setSendError(e?.message || 'Couldn’t send. Your draft is still here.')
      setSending(false)
    }
  }, [draft.id, draft.toAddress, draft.attachments, sendDraft, sending, uploading, signatureLoading])

  const handleDiscardRequest = useCallback(() => {
    setConfirmDiscard(true)
  }, [])

  const handleDiscardConfirm = useCallback(() => {
    setConfirmDiscard(false)
    deleteDraft(draft.id)
  }, [draft.id, deleteDraft])

  const handleDiscardCancel = useCallback(() => {
    setConfirmDiscard(false)
  }, [])

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        // Keep Escape scoped to the composer — without this it bubbles to the
        // window-level handlers that deselect/close the open conversation.
        e.stopPropagation()
        // Untouched reply/forward scaffolding → discard it entirely rather than
        // leaving a draft behind; an edited one asks first.
        if (dirtyRef.current) setConfirmClose(true)
        else deleteDraft(draft.id)
      }
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        e.preventDefault()
        handleSend()
      }
    }
    const el = popupRef.current
    if (el) {
      el.addEventListener('keydown', handler)
      return () => el.removeEventListener('keydown', handler)
    }
  }, [draft.id, deleteDraft, handleSend])

  return (
    <div className={styles.popup} ref={popupRef} tabIndex={-1} role="presentation" data-overlay-open
      onDragOver={handleDragOver} onDrop={handleDrop}>
      <div className={styles.resizeHandle} onPointerDown={handleResizeStart}
        role="separator" aria-label="Resize compose window" title="Drag to resize" />
      {sending && <div className={styles.sendingBar}><SyncProgressBar label="Sending" /></div>}
      <div className={`${styles.content} ${sending ? styles.locked : ''}`} inert={sending}>
      <ComposeHeader
        toAddress={draft.toAddress}
        ccAddress={draft.ccAddress}
        fromAddress={draft.fromAddress}
        bccAddress={draft.bccAddress}
        subject={draft.subject}
        fromIdentities={fromIdentities}
        onToChange={v => handleFieldChange('toAddress', v)}
        onCcChange={v => handleFieldChange('ccAddress', v)}
        onBccChange={v => handleFieldChange('bccAddress', v)}
        onFromChange={v => handleFieldChange('fromAddress', v)}
        onSubjectChange={v => handleFieldChange('subject', v)}
        onMinimize={() => minimizeDraft(draft.id)}
        onClose={() => (dirtyRef.current ? setConfirmClose(true) : closeDraft(draft.id))}
      />

      <div className={styles.attachmentBar}>
        <label className={styles.attachmentLabel}>Attachments</label>
        <div className={styles.attachmentChips}>
          {draft.attachments.map(att => {
            const bytes = att.size ?? att.byte_size ?? att.data?.length
            return (
              <span key={att.key} className={`${styles.attachmentChip} ${att.pending ? styles.attachmentPending : ''}`} title={att.filename}>
                {att.pending
                  ? <span className={styles.attachmentSpinner} aria-label="Downloading" />
                  : <FileIcon filename={att.filename} size={16} />}
                <span className={styles.attachmentName}>{att.filename}</span>
                {att.failed
                  ? <span className={styles.attachmentSize}>failed</span>
                  : att.pending
                    ? null
                    : bytes ? <span className={styles.attachmentSize}>{formatBytes(bytes)}</span> : null}
                <button
                  className={styles.attachmentRemove}
                  onClick={() => removeAttachment(draft.id, att.key)}
                  aria-label={`Remove ${att.filename}`}
                >&times;</button>
              </span>
            )
          })}
        </div>
        <Checkbox
          className={styles.previewToggle}
          checked={showPreview}
          onChange={e => {
            setShowPreview(e.target.checked)
            localStorage.setItem(COMPOSE_PREVIEW, String(e.target.checked))
          }}
        >Preview</Checkbox>
        <ToolbarButton icon="paperclip" onClick={handleAttach} disabled={uploading}>
          {uploading ? 'Uploading…' : 'Attach'}
        </ToolbarButton>
        {diskOrgId && (
          <>
            <ToolbarButton icon="externaldrive" onClick={() => setDiskPick('attach')} disabled={uploading}>From Disk</ToolbarButton>
            <ToolbarButton icon="link" onClick={() => setDiskPick('link')} disabled={!editor}>Disk link</ToolbarButton>
          </>
        )}
      </div>

      <div className={styles.body}>
        <div className={styles.editorPane}>
          <Suspense fallback={null}>
            <RichEditor
              content={draft.bodyHtml}
              placeholder="Write your message..."
              onUpdate={handleEditorUpdate}
              yjsDoc={yjsRef?.doc}
              provider={yjsRef?.provider}
              autofocus={draft.focus === 'body' ? 'end' : false}
              onEditor={setEditor}
            />
          </Suspense>
        </div>
        {showPreview && <PreviewPane html={previewHtml} quotedHtml={draft.quotedHtml} />}
      </div>
      </div>

      <ComposeFooter
        saveStatus={draft.saveStatus}
        sending={sending}
        sendError={sendError}
        onSend={handleSend}
        onDiscard={handleDiscardRequest}
        // While the new From address's signature loads, the old one is still in the body.
        sendDisabled={hasPendingAttachments || uploading || signatureLoading}
        sendDisabledTitle={uploading ? 'Wait for the upload to finish.' : hasPendingAttachments ? 'Waiting for attachments to finish downloading…' : 'Loading your signature…'}
      />

      <input
        ref={fileInputRef}
        type="file"
        multiple
        className={styles.hiddenInput}
        onChange={handleFileSelected}
      />

      <ConfirmDialog
        open={confirmClose}
        title={isLocalDraft ? 'Discard this message?' : 'Close this message?'}
        message={isLocalDraft
          ? "It isn't saved anywhere, so closing loses it."
          : 'It stays in Drafts for later.'}
        confirmLabel={isLocalDraft ? 'Discard' : 'Close'}
        cancelLabel="Keep editing"
        variant={isLocalDraft ? 'danger' : 'warning'}
        onConfirm={() => {
          setConfirmClose(false)
          if (isLocalDraft) deleteDraft(draft.id)
          else closeDraft(draft.id)
        }}
        onCancel={() => setConfirmClose(false)}
      />
      {diskPick && (
        <Suspense fallback={null}>
          <DiskPicker orgId={diskOrgId} pickFiles verb={diskPick === 'link' ? 'Link' : 'Attach'} onClose={() => setDiskPick(null)} onPick={pickFromDisk} />
        </Suspense>
      )}
      <ConfirmDialog
        open={!!tooBig}
        title="Too large to send"
        message={tooBigMessage(tooBig)}
        confirmLabel={tooBig?.files ? 'Upload and insert link' : 'Insert link'}
        cancelLabel="Cancel"
        onConfirm={() => { const t = tooBig; setTooBig(null); if (t.files) linkInstead(t.files); else whileBusy(() => insertDiskLink(t.node)) }}
        onCancel={() => setTooBig(null)}
      />
      <ConfirmDialog
        open={confirmDiscard}
        title="Discard draft?"
        message="You’ll lose this draft for good."
        confirmLabel="Discard"
        cancelLabel="Keep editing"
        variant="danger"
        onConfirm={handleDiscardConfirm}
        onCancel={handleDiscardCancel}
      />
    </div>
  )
}
