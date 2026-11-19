// @vitest-environment jsdom
import { describe, it, expect } from 'vitest'
import { sanitizePreviewHtml, filterInlineStyle } from '../previewSanitizer'

describe('sanitizePreviewHtml', () => {
  it('keeps emphasis from quoted mail', () => {
    const out = sanitizePreviewHtml('<p><b>bold</b> <i>italic</i> <strong>s</strong></p>')
    expect(out).toContain('<b>bold</b>')
    expect(out).toContain('<i>italic</i>')
    expect(out).toContain('<strong>s</strong>')
  })

  it('keeps line breaks and paragraph structure', () => {
    const out = sanitizePreviewHtml('<div>Rate: 100<br>Hours: 36</div>')
    expect(out).toBe('<div>Rate: 100<br>Hours: 36</div>')
  })

  it('drops scripts and event handlers', () => {
    const out = sanitizePreviewHtml('<p onclick="x()">hi</p><script>bad()</script>')
    expect(out).toBe('<p>hi</p>')
  })
})

describe('filterInlineStyle', () => {
  it('keeps Outlook paragraph margins and inline bolding', () => {
    expect(filterInlineStyle('margin-top:1em;font-weight:bold'))
      .toBe('margin-top: 1em; font-weight: bold')
  })

  it('strips colors, fonts and url()', () => {
    expect(filterInlineStyle('color:#000;font-family:Wingdings;font-size:2px')).toBe('')
    expect(filterInlineStyle('margin: url(evil.png)')).toBe('')
  })
})
