// Mail and Disk (spec F9). MX mail goes through the API; channel mail
// (Gmail/Microsoft/IMAP) never touches it, so its bytes move in this client:
// saving reads them from the local engine into the Disk upload queue, attaching
// fetches the Disk file and hands the bytes to the local compose.
import diskApi, { ATTACHMENT_TOO_LARGE, KEEP_BOTH } from './api'
import { isMxAttachment } from '../mxAttachments'

/** Saves a received attachment into a Disk folder. Returns 'saved' (MX, done) or 'queued' (channel, in the upload panel). */
export async function saveAttachmentToDisk({ orgId, message, attachment, parentId }) {
  // ponytail: sealed mail stays out of Disk until sealed folders take it (package 9).
  if (attachment.sealed) throw new Error("You can't save sealed attachments to Disk yet")
  if (isMxAttachment(attachment)) {
    await diskApi.saveToDisk(orgId, message.key || message.id, attachment.mxKey, { parent_id: parentId, on_conflict: KEEP_BOTH })
    return 'saved'
  }
  const [{ resolveAccountKey }, { downloadAttachmentBytes }, { enqueue }] = await Promise.all([
    import('../draftAttachments'), import('../providers/index.js'), import('./upload'),
  ])
  const accountKey = await resolveAccountKey(message)
  if (!accountKey) throw new Error('No account found for this message')
  const bytes = await downloadAttachmentBytes(accountKey, message.key || message.id, attachment)
  const file = new File([bytes], attachment.name, { type: attachment.mimeType || 'application/octet-stream' })
  await enqueue(orgId, parentId, [{ file, relativePath: file.name }])
  return 'queued'
}

/**
 * A Disk file as a draft attachment. apiDraft: the draft sends through the API
 * by attachment key; otherwise the bytes go into the local compose.
 * Throws with .tooLarge (and .limitBytes) when it is over the mail limit.
 */
export async function attachmentFromDisk({ orgId, draftId, apiDraft, node }) {
  if (apiDraft) {
    try {
      const { attachment } = await diskApi.attachFromDisk(orgId, draftId, node.id)
      return { ...attachment, key: attachment.id }
    } catch (e) {
      if (e.data?.code === ATTACHMENT_TOO_LARGE) Object.assign(e, { tooLarge: true, limitBytes: e.data.limit_bytes })
      throw e
    }
  }
  const { download } = await diskApi.download(orgId, node.id)
  const res = await fetch(download.url)
  if (!res.ok) throw new Error(`Couldn't read ${node.name} (${res.status})`)
  const data = new Uint8Array(await res.arrayBuffer())
  return { key: `disk_${node.id}`, filename: node.name, content_type: node.mime || 'application/octet-stream', data, size: data.length }
}

/**
 * May a file too big to mail go onto Disk and out as a link? Never from a sealed
 * domain: uploadForLink stores a readable copy behind a public link, which is what
 * sealing exists to prevent. The From address decides, as it does for the send
 * (OutboundMessageSealer.sealing_domain). An inbox2 From on a domain this client
 * can't see counts as sealed, so an unknown stays closed.
 */
export function mayLinkInstead({ domains = [], fromAddress = '', viaProvider = false }) {
  const name = fromAddress.split('@').pop().trim().toLowerCase()
  const domain = domains.find((d) => d.name?.toLowerCase() === name)
  if (domain) return !domain.e2ee_enabled
  return viaProvider
}

// Where a file too big to mail goes on the member's own disk before it is linked.
export const MAIL_FOLDER = 'Mail attachments'

/**
 * A file from the computer that is too big to mail: uploads it to
 * C:\Mail attachments and resolves with its node ({ id, name }) for linkForMail.
 * It goes through the Disk upload queue (parts, retries); a name already there
 * keeps both, because the composer has no panel to ask in.
 */
export async function uploadForLink(orgId, file, { onProgress } = {}) {
  const [{ enqueue }, { default: useUploadStore, UPLOAD_STATE: S }] = await Promise.all([import('./upload'), import('../../stores/uploadStore')])
  const { c_drive: drive } = await diskApi.drives(orgId)
  const [id] = await enqueue(orgId, drive.id, [{ file, relativePath: `${MAIL_FOLDER}/${file.name}` }], { onConflict: KEEP_BOTH })
  return new Promise((resolve, reject) => {
    const check = ({ items }) => {
      const it = items.find((i) => i.id === id)
      if (!it) return done(reject, new Error('The upload was removed'))
      onProgress?.(it.size ? it.loaded / it.size : 0)
      if (it.state === S.DONE) return done(resolve, { id: it.nodeId, name: it.name })
      if ([S.ERROR, S.CANCELLED, S.INTERRUPTED].includes(it.state)) return done(reject, new Error(it.error || "The upload didn't finish"))
      return undefined
    }
    const stop = useUploadStore.subscribe(check)
    function done(settle, value) { stop(); settle(value) }
    check(useUploadStore.getState())
  })
}

/** A public link to put in the body: { url, name }. */
export async function linkForMail(orgId, node) {
  const { link } = await diskApi.createLink(orgId, node.id, {})
  return { url: link.url, name: node.name }
}
