// @vitest-environment jsdom
import { describe, it, expect } from 'vitest'
import { demoWaChats, demoWaMessages, demoWaSearch, demoWaLoreRows, demoWaChatMedia } from '../demoWhatsApp'
import { toChatMessage } from '../waMessages'
import { waItem } from '../lore'

describe('demo WhatsApp', () => {
  it('lists fictional chats newest first, with an archived one', () => {
    const chats = demoWaChats()
    expect(chats.length).toBeGreaterThan(4)
    expect(chats.every((c, i) => i === 0 || chats[i - 1].last_at >= c.last_at)).toBe(true)
    expect(chats.some((c) => c.archived)).toBe(true)
  })

  it('renders through the real message mapping, photos from the app itself', () => {
    const msgs = demoWaMessages(9001).messages.map(toChatMessage).filter(Boolean)
    const photo = msgs.find((m) => m.attachments.some((a) => a.kind === 'image'))
    expect(photo.attachments[0].url).toBe('/images/a4.jpg')
    expect(demoWaChatMedia(9001)).toHaveLength(1)
  })

  it('searches its own text and feeds Lore', () => {
    expect(demoWaSearch('signed contract').map((h) => h.chat_name)).toContain('Sarah Chen')
    const items = demoWaLoreRows().map((r) => waItem(r)).filter(Boolean)
    expect(items).toHaveLength(3)
    expect(items.find((i) => i.chatId === 9004).amount).toBeTruthy()
  })
})
