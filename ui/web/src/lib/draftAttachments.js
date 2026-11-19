import { getDb } from './db.js'
import log from './log'
import { isMxAttachment, mapMxAttachments } from './mxAttachments'

/**
 * Resolve the provider account key that owns a message, from the local SQLite
 * store (provider state first, then the messages table).
 */
export async function resolveAccountKey(message) {
  const messageKey = message.key || message.id
  const db = await getDb()
  const mpsRows = await db.select(
    'SELECT account_key FROM message_provider_state WHERE message_key = ? LIMIT 1',
    [messageKey]
  )
  if (mpsRows.length > 0) return mpsRows[0].account_key
  const msgRows = await db.select('SELECT account_key FROM messages WHERE key = ? LIMIT 1', [messageKey])
  if (msgRows.length > 0) return msgRows[0].account_key
  return null
}

/**
 * Build a *pending* draft-attachment that carries no bytes yet — just the
 * metadata plus a `download` ref. Seeded into `createDraft({ attachments })` so
 * the composer opens instantly; ComposePopup then downloads the bytes (cached),
 * shows a spinner on the chip, and blocks Send until every pending one resolves.
 */
export function forwardAttachmentPlaceholder(accountKey, messageKey, attachment) {
  const filename = attachment.name || attachment.filename || 'attachment'
  const attachmentId = attachment.attachmentId || attachment.attachment_id
  return {
    key: `fwd_${messageKey}_${attachmentId}`,
    filename,
    content_type: attachment.mimeType || 'application/octet-stream',
    // Known size (numeric) shows immediately; otherwise it fills in post-download.
    size: typeof attachment.size === 'number' ? attachment.size : undefined,
    pending: true,
    download: { accountKey, messageKey, attachmentId },
  }
}

/**
 * Pending placeholder for an MX (inbox2-hosted) attachment. MX mail has no
 * provider account: ComposePopup streams the bytes from the org's storage via
 * `mxForward`, which carries `sealed` so a sealed attachment can be decrypted.
 */
export function mxForwardPlaceholder(attachment, message) {
  return {
    key: `fwd_${attachment.mxKey}`,
    filename: attachment.name,
    content_type: attachment.mimeType || 'application/octet-stream',
    size: attachment.sizeBytes,
    pending: true,
    mxForward: { attachment, message: { key: message?.key || message?.id, sealed: message?.sealed } },
  }
}

/**
 * Pending placeholders for every attachment of a message, ready to seed into
 * `createDraft({ attachments })`. MX attachments stream from the org's storage;
 * provider ones download through their account. Returns [] when there are none.
 */
export async function forwardAttachmentPlaceholders(message) {
  const attachments = mapMxAttachments(message?.attachments)
  if (attachments.length === 0) return []
  // MX mail has no local account: resolving one returned null and dropped every
  // attachment from a web forward (2026-11-19 feedback).
  const mx = attachments.filter(isMxAttachment)
  if (mx.length > 0) return mx.map(a => mxForwardPlaceholder(a, message))
  const accountKey = await resolveAccountKey(message)
  if (!accountKey) {
    log.warn('Attachment', `forward: no account key for message ${message?.key || message?.id}`)
    return []
  }
  const messageKey = message.key || message.id
  return attachments.map(a => forwardAttachmentPlaceholder(accountKey, messageKey, a))
}
