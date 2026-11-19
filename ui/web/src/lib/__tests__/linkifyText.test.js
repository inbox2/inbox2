// @vitest-environment jsdom
import { describe, it, expect } from 'vitest'
import { linkifyText } from '../linkifyText'

describe('linkifyText', () => {
  it('links URLs and keeps trailing punctuation outside', () => {
    expect(linkifyText('see https://a.nl/x.')).toBe('see <a href="https://a.nl/x">https://a.nl/x</a>.')
  })

  it('cannot break out of the href attribute', () => {
    const html = linkifyText('https://evil.example/"onmouseover="alert(1)')
    const el = document.createElement('div')
    el.innerHTML = html
    const a = el.querySelector('a')
    expect(a.getAttributeNames()).toEqual(['href'])
    expect(a.getAttribute('href')).toBe('https://evil.example/"onmouseover="alert(1')
  })
})
