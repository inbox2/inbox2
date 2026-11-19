// @vitest-environment jsdom
import { describe, it, expect } from 'vitest'
import { toChatMessage } from '../waMessages'
import { WA_KIND } from '../localWhatsApp'

const base = { id: 7, chat_id: 1, from_me: false, at: Date.UTC(2026, 9, 25, 21, 0), text: null, sender: 'Badr', sender_avatar: null, media: null }
const media = (over) => ({ path: null, thumb: null, title: null, name: null, aspect: 0, size: 0, duration: 0, latitude: 0, longitude: 0, ...over })

describe('toChatMessage', () => {
  it('maps text, sender and direction', () => {
    const m = toChatMessage({ ...base, kind: WA_KIND.TEXT, text: 'Heb me geld terug' })
    expect(m).toMatchObject({ id: 'wa-7', waId: 7, is_inbound: true, body_plain: 'Heb me geld terug', sender_label: 'Badr', attachments: [] })
    expect(toChatMessage({ ...base, kind: WA_KIND.TEXT, text: 'hi', from_me: true }).sender_label).toBeNull()
  })

  it('serves a downloaded photo through wamedia:// with its caption', () => {
    const m = toChatMessage({ ...base, kind: WA_KIND.IMAGE, media: media({ path: 'Message/Media/x@g.us/8/5/a b.jpg', title: 'sane defaults', aspect: 1.5 }) })
    expect(m.body_plain).toBe('sane defaults')
    expect(m.attachments[0]).toMatchObject({ kind: 'image', path: 'Message/Media/x@g.us/8/5/a b.jpg', aspect: 1.5, missing: false })
    expect(m.attachments[0].url).toBe('wamedia://localhost/Message/Media/x%40g.us/8/5/a%20b.jpg')
  })

  it('says when media never reached this Mac', () => {
    const m = toChatMessage({ ...base, kind: WA_KIND.DOCUMENT, text: 'plan.pdf', media: media({ size: 10 }) })
    expect(m.attachments[0]).toMatchObject({ kind: 'document', name: 'plan.pdf', size: 10, missing: true, path: null })
    expect(toChatMessage({ ...base, kind: WA_KIND.AUDIO, media: media({ duration: 7 }) }).attachments[0]).toMatchObject({ kind: 'missing', label: 'Voice message' })
  })

  it('gives each media type its own kind', () => {
    const at = (kind, over) => toChatMessage({ ...base, kind, media: media({ path: 'Message/Media/c/x.bin', ...over }) }).attachments[0].kind
    expect(at(WA_KIND.VIDEO)).toBe('video')
    expect(at(WA_KIND.GIF)).toBe('gif')
    expect(at(WA_KIND.AUDIO)).toBe('audio')
    expect(at(WA_KIND.STICKER)).toBe('sticker')
    expect(toChatMessage({ ...base, kind: WA_KIND.LINK, text: 'https://a.nl', media: media({ thumb: 'Message/Media/c/x.mmsthumb', title: 'A' }) }).attachments[0]).toMatchObject({ kind: 'link', name: 'A' })
  })

  it('marks deleted messages (shown in italics)', () => {
    expect(toChatMessage({ ...base, kind: WA_KIND.DELETED })).toMatchObject({ body_plain: 'This message was deleted', deleted: true })
    expect(toChatMessage({ ...base, kind: WA_KIND.TEXT, text: 'hoi' }).deleted).toBe(false)
  })

  it('turns group events into system rows and drops empty protocol rows', () => {
    expect(toChatMessage({ ...base, kind: WA_KIND.SYSTEM, text: 'Papa Zusjes Party' })).toMatchObject({ system: true, body: 'Papa Zusjes Party' })
    expect(toChatMessage({ ...base, kind: 59 })).toBeNull()
  })
})

describe('waItem (Lore)', () => {
  it('maps an open WhatsApp ask to a Lore item that opens the chat at the ask', async () => {
    const { waItem, WA_SOURCE } = await import('../lore')
    const item = waItem({
      chat_id: 1123, chat_name: 'Gluon 👾', is_group: 1, sender: 'Badr', avatar: null, ask_from_id: 124315,
      ask_at: '2026-10-25T21:10:00Z', label: 'needs_answer', priority: 3, title: 'Kies defaults voor de connector',
      summary: 'Zes vragen over de SharePoint connector.', status: 'open',
    })
    expect(item).toMatchObject({ uid: 'whatsapp:wa:1123', source: WA_SOURCE, chatId: 1123, askId: 124315, title: 'Kies defaults voor de connector', from: 'Badr', address: null, domain: null, isGroup: true })
    expect(item.bucket).toBeTruthy()
    expect(waItem({ chat_id: 1, chat_name: 'x', ask_at: '2026-10-25T21:10:00Z', label: 'resolved', status: 'open' })).toBeNull()
  })
})

describe('mergeNewest (live refresh)', () => {
  it('keeps what was paged in and appends/replaces from the newest page', async () => {
    const { mergeNewest } = await import('../waMessages')
    const m = (id, t = '') => ({ id, text: t })
    const page = { chatId: 1, messages: [m(1), m(2), m(3), m(4)], hasEarlier: true }
    const merged = mergeNewest(page, { messages: [m(3), m(4, 'edited'), m(5)], has_earlier: true })
    expect(merged.messages.map(x => x.id)).toEqual([1, 2, 3, 4, 5])
    expect(merged.messages[3].text).toBe('edited')
    expect(merged.hasEarlier).toBe(true)
    expect(mergeNewest(page, { messages: [m(9)], has_earlier: true }).messages.map(x => x.id)).toEqual([9])
  })
})
