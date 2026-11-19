import { describe, it, expect, vi } from 'vitest'

vi.mock('../db.js', () => ({ getDb: vi.fn(async () => ({ select: async () => [] })) }))

import { forwardAttachmentPlaceholders } from '../draftAttachments'

describe('forwardAttachmentPlaceholders', () => {
  it('carries MX attachments (no local account) as mxForward placeholders', async () => {
    const message = {
      key: 'msg_1',
      sealed: false,
      attachments: [{ id: 'att_1', filename: 'offerte.pdf', content_type: 'application/pdf', size_bytes: 1200 }],
    }
    const [att] = await forwardAttachmentPlaceholders(message)
    expect(att).toMatchObject({ key: 'fwd_att_1', filename: 'offerte.pdf', pending: true, size: 1200 })
    expect(att.mxForward.message).toEqual({ key: 'msg_1', sealed: false })
  })

  it('returns [] for a provider message with no local account', async () => {
    const message = { key: 'msg_2', attachments: [{ name: 'a.txt', attachmentId: 'x' }] }
    expect(await forwardAttachmentPlaceholders(message)).toEqual([])
  })
})
