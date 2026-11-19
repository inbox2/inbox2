// WhatsApp Desktop message rows (whatsapp.rs `WaMessage`) → the message shape
// ChatThread renders. Pure: opening, saving and dragging media are the
// viewer's and the bubble's business (components/ChatThread/MediaAttachment).
import { WA_KIND, waMediaUrl } from './localWhatsApp'

/** "1:07" from seconds. */
export function duration(secs) {
  const s = Math.round(secs || 0)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

/** The attachment kinds MediaAttachment draws (and the viewer opens). */
export const MEDIA = {
  IMAGE: 'image', STICKER: 'sticker', GIF: 'gif', VIDEO: 'video', AUDIO: 'audio',
  DOCUMENT: 'document', LINK: 'link', MISSING: 'missing',
}

// One media item → a ChatThread attachment with a `kind`. `path`/`thumb` stay
// container-relative (for saving, Finder and drag-out); `url`/`thumbUrl` are
// what the webview loads. Media never downloaded on this Mac keeps its
// thumbnail when WhatsApp has one, else becomes a "missing" chip.
function attachment(m) {
  const media = m.media
  if (!media) return null
  const base = {
    attachmentId: m.id,
    waId: m.id,
    path: media.path || null,
    thumb: media.thumb || null,
    thumbUrl: waMediaUrl(media.thumb),
    name: media.name || null,
    size: media.size || null,
    aspect: media.aspect || 0,
    duration: media.duration || 0,
    missing: !media.path,
  }
  const missing = (label) => ({ ...base, kind: MEDIA.MISSING, label })
  switch (m.kind) {
    case WA_KIND.IMAGE:
      return media.path || media.thumb ? { ...base, kind: MEDIA.IMAGE, url: waMediaUrl(media.path || media.thumb) } : missing('Photo')
    case WA_KIND.STICKER:
      return media.path ? { ...base, kind: MEDIA.STICKER, url: waMediaUrl(media.path) } : missing('Sticker')
    case WA_KIND.GIF:
      return media.path ? { ...base, kind: MEDIA.GIF, url: waMediaUrl(media.path) } : missing('GIF')
    case WA_KIND.VIDEO:
      return media.path || media.thumb ? { ...base, kind: MEDIA.VIDEO, url: waMediaUrl(media.path) } : missing('Video')
    case WA_KIND.AUDIO:
      return media.path ? { ...base, kind: MEDIA.AUDIO, url: waMediaUrl(media.path) } : missing('Voice message')
    case WA_KIND.DOCUMENT:
      return { ...base, kind: MEDIA.DOCUMENT, url: waMediaUrl(media.path), name: (m.text || media.name || 'Document').replace(/^\u200e/, '') }
    case WA_KIND.LINK:
      return media.thumb ? { ...base, kind: MEDIA.LINK, name: media.title || null } : null
    default:
      return null
  }
}

// What a message says, for the kinds that carry no text of their own.
function bodyText(m) {
  switch (m.kind) {
    case WA_KIND.IMAGE:
    case WA_KIND.VIDEO:
      return m.media?.title || m.text || ''
    case WA_KIND.DOCUMENT:
      return '' // the filename is on the chip
    case WA_KIND.LOCATION:
      return m.media?.latitude
        ? `📍 Location\nhttps://maps.apple.com/?ll=${m.media.latitude},${m.media.longitude}`
        : '📍 Location'
    case WA_KIND.CONTACT: return '👤 Contact card'
    case WA_KIND.POLL:
    case WA_KIND.POLL_V2: return `📊 Poll${m.text ? `: ${m.text}` : ''}`
    case WA_KIND.DELETED: return 'This message was deleted'
    default: return m.text || ''
  }
}

// A WhatsApp row → the message shape ChatThread renders. Null for the kinds
// with nothing to show (reactions, key changes and other protocol rows).
export function toChatMessage(m) {
  const created_at = new Date(m.at).toISOString()
  if (m.kind === WA_KIND.SYSTEM || m.kind === WA_KIND.CALL) {
    return m.text ? { id: `wa-${m.id}`, created_at, system: true, body: m.text } : null
  }
  const att = attachment(m)
  const body_plain = bodyText(m)
  if (!body_plain && !att) return null
  return {
    id: `wa-${m.id}`,
    waId: m.id,
    created_at,
    is_inbound: !m.from_me,
    body_plain,
    sender_label: m.from_me ? null : m.sender,
    // Rendered in italics, muted (WhatsApp's own look for a deleted message).
    deleted: m.kind === WA_KIND.DELETED,
    avatar_url: waMediaUrl(m.sender_avatar),
    attachments: att ? [att] : [],
  }
}

/**
 * The page so far + a fresh newest page → one page. The fresh page is the newest
 * page of messages, contiguous: everything loaded before its first message stays,
 * the rest is replaced by it (new appended, edited/deleted rows updated). When it
 * doesn't overlap (more than PAGE new messages at once) it starts over from it.
 */
export function mergeNewest(page, fresh) {
  const first = fresh.messages[0]
  const at = first ? page.messages.findIndex(m => m.id === first.id) : -1
  if (at < 0) return { ...page, messages: fresh.messages, hasEarlier: fresh.has_earlier }
  return { ...page, messages: [...page.messages.slice(0, at), ...fresh.messages] }
}
