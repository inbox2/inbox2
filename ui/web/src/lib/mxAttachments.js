// Attachments on MX (inbox2-hosted) mail.
//
// The local-channel path (Gmail/Outlook/IMAP) fetches attachments from the
// provider through the Rust engine — see lib/providers/index.js. MX mail has no
// provider: the bytes live in the org's own object storage and come back from
// `GET /orgs/:org/attachments/:key`, which streams them.
//
// Inbound MX mail has created Attachment rows since the MX receiver shipped, and
// that endpoint has always existed — but the message payload never carried them,
// so every attachment on every MX message was invisible in every client. This
// module is the client half of closing that.

import api from './api';
import log from './log';
import formatBytes from './formatBytes';
import { isTauri } from './tauri';

// An attachment this module owns, vs one from a provider account. Only the MX
// mapping below sets `mxKey`; provider ones carry an `attachmentId` instead.
export function isMxAttachment(attachment) {
  return !!attachment?.mxKey;
}

/**
 * Map the API's attachment payload onto the shape MessageDetails renders.
 * Pass-through for anything already in UI shape (a provider attachment that
 * lib/conversationDetail.js mapped), so a caller can hand this a mixed list.
 *
 * Sealed attachments (docs/E2EE.md) arrive with `filename: null` — the name is
 * ciphertext in `sealed_filename`. `useSealedMessages` decrypts it once the
 * identity is unlocked and rewrites `filename`; until then the chip shows the
 * placeholder, and a download while still locked fails in decryptSealedAttachment
 * rather than handing the user a file of ciphertext.
 */
export function mapMxAttachments(attachments) {
  return (attachments || []).map((a, index) => {
    if (a.name && !a.filename) return a; // already UI shape
    const sealed = !!a.sealed_filename;
    return {
      name: a.filename || (sealed ? 'Encrypted attachment' : 'attachment'),
      size: a.size_bytes ? formatBytes(a.size_bytes) : undefined,
      sizeBytes: a.size_bytes,
      mimeType: a.content_type,
      mxKey: a.id,
      downloadUrl: a.download_url,
      hasContent: a.has_content,
      sealed,
      sealedIndex: index,
      sealed_filename: a.sealed_filename,
      filename_nonce: a.filename_nonce,
      content_nonce: a.content_nonce,
    };
  });
}

/**
 * The attachment's bytes, decrypted when the message is sealed.
 * @returns {Promise<Uint8Array>}
 */
export async function mxAttachmentBytes(attachment, message) {
  if (!attachment.downloadUrl) throw new Error("This attachment isn't available");
  const bytes = await api.getBlob(attachment.downloadUrl);
  if (!attachment.sealed) return bytes;
  // Sealed: what storage holds is ciphertext. Handing that to the OS would open
  // a file of noise, so decrypt or fail — never save the raw blob.
  const { decryptSealedAttachment } = await import('./e2eeStore');
  return decryptSealedAttachment(message, attachment, attachment.sealedIndex, bytes);
}

/** Download + open with the system handler (desktop) or the browser (web). */
export async function openMxAttachment(attachment, message) {
  const bytes = await mxAttachmentBytes(attachment, message);
  const filename = attachment.name || 'attachment';
  if (isTauri()) {
    const { invoke } = await import('@tauri-apps/api/core');
    // Reuses the engine's attachment cache dir + system-open, so an MX file
    // opens exactly the way a Gmail one does.
    await invoke('save_and_open_attachment', {
      accountKey: 'mx', messageKey: message?.key || message?.id || 'mx',
      filename, data: Array.from(bytes),
    });
    return;
  }
  browserSave(bytes, filename, attachment.mimeType);
}

/** Save to a user-chosen location (desktop) / the downloads folder (web). */
export async function saveMxAttachmentAs(attachment, message) {
  const bytes = await mxAttachmentBytes(attachment, message);
  const filename = attachment.name || 'attachment';
  if (isTauri()) {
    const { invoke } = await import('@tauri-apps/api/core');
    return invoke('save_attachment_as', { filename, data: Array.from(bytes) });
  }
  browserSave(bytes, filename, attachment.mimeType);
  return filename;
}

// Web has no native save dialog: hand the bytes to the browser's own download
// machinery. Anchor-click rather than navigating, so the app doesn't unload.
export function browserSave(bytes, filename, mimeType) {
  const url = URL.createObjectURL(new Blob([bytes], { type: mimeType || 'application/octet-stream' }));
  try {
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.rel = 'noopener';
    document.body.appendChild(a);
    a.click();
    a.remove();
  } catch (e) {
    log.warn('Attachment', `browser save failed for ${filename}: ${e?.message || e}`);
  } finally {
    // Give the click a tick to start the download before the URL dies.
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
}
