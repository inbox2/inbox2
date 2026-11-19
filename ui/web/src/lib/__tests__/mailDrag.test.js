import { describe, it, expect } from 'vitest'
import { buildEml, param, isLocalStandIn, addressHeader, encodeWords } from '../mailDrag'

const decode = (b) => new TextDecoder().decode(Uint8Array.from(atob(b.replace(/\s/g, '')), (c) => c.charCodeAt(0)))

describe('buildEml', () => {
  it('writes headers and both bodies as multipart/alternative', () => {
    const eml = buildEml({ from_address: 'Ana <ana@x.nl>', to_address: 'me@y.nl', subject: 'Offerte één', body_plain: 'hoi', body_html: '<p>hoi</p>', created_at: '2026-10-25T10:00:00Z', message_id: 'abc@x.nl' })
    expect(eml).toMatch(/^From: "Ana" <ana@x\.nl>\r\n/)
    expect(eml).toContain('Subject: =?UTF-8?B?')
    expect(eml).toContain('Message-ID: <abc@x.nl>')
    expect(eml).toContain('Content-Type: multipart/alternative; boundary="inbox2-')
    expect(eml).toContain('Content-Type: text/html; charset=UTF-8')
    const subject = eml.match(/Subject: =\?UTF-8\?B\?([^?]+)\?=/)[1]
    expect(decode(subject)).toBe('Offerte één')
  })

  it('embeds attachments as multipart/mixed parts', () => {
    const eml = buildEml({ from_address: 'a@b.nl', subject: 'x', body_plain: 'hi' }, [{ name: 'f.txt', type: 'text/plain', bytes: new TextEncoder().encode('file body') }])
    expect(eml).toContain('Content-Type: multipart/mixed; boundary="inbox2-mix-')
    expect(eml).toContain('Content-Disposition: attachment; filename="f.txt"')
    const part = eml.split('filename="f.txt"\r\n\r\n')[1].split('\r\n--')[0]
    expect(decode(part)).toBe('file body')
  })

  it('encodes awkward attachment names', () => {
    expect(param('filename', 'John "proposal".pdf')).toBe('filename="John \\"proposal\\".pdf"')
    expect(param('filename', 'a\\b.txt')).toBe('filename="a\\\\b.txt"')
    expect(param('filename', 'één.pdf')).toBe("filename*=UTF-8''%C3%A9%C3%A9n.pdf")
  })

  it('tells the engine\'s local stand-in from a real source', () => {
    expect(isLocalStandIn('From: a@b.nl\nTo: c@d.nl\nSubject: x\n\nbody')).toBe(true)
    expect(isLocalStandIn('From: a@b.nl\r\nMIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nbody')).toBe(false)
  })

  it('encodes display names only, so addresses stay readable', () => {
    const h = addressHeader('José <j@example.com>, Ann Lee <a@b.nl>, plain@x.nl')
    expect(h).toContain('<j@example.com>')
    expect(h).toMatch(/^=\?UTF-8\?B\?[^?]+\?= <j@example\.com>,\r\n "Ann Lee" <a@b\.nl>,\r\n plain@x\.nl$/)
  })

  it('splits long non-ASCII text into short encoded words', () => {
    const words = encodeWords('é'.repeat(60)).split('\r\n ')
    expect(words.length).toBeGreaterThan(1)
    expect(words.every((w) => w.length <= 75)).toBe(true)
    expect(words.map((w) => decode(w.slice(10, -2))).join('')).toBe('é'.repeat(60))
  })

  it('takes a local message\'s Message-ID from message_id_header', () => {
    expect(buildEml({ from_address: 'a@b.nl', message_id_header: '<x1@b.nl>', subject: 's', body_plain: 'b' })).toContain('Message-ID: <x1@b.nl>\r\n')
  })

  it('keeps Bcc', () => {
    expect(buildEml({ from_address: 'me@x.nl', bcc_address: 'boss@x.nl', subject: 's', body_plain: 'b' })).toContain('Bcc: boss@x.nl\r\n')
  })

  it('writes a single body without a multipart wrapper', () => {
    const eml = buildEml({ from_address: 'a@b.nl', subject: 'x', body_plain: 'plain only' })
    expect(eml).toContain('Content-Type: text/plain; charset=UTF-8')
    expect(eml).not.toContain('multipart')
    expect(decode(eml.split('\r\n\r\n')[1])).toBe('plain only')
  })
})
