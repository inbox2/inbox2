import DOMPurify from 'dompurify'
import { blockRemoteContent, BLOCKED_TAGS, BLOCKED_ATTR } from '@inbox2/email-body'
import log from '../../lib/log'

// Theme-aware email HTML sanitizer for the plain/inline (QuotedText) render path,
// extracted so it can be unit-tested apart from the React component (see
// QuotedText.stories.jsx, which runs in a real browser because the colour parsing
// needs a <canvas> 2d context). See docs/Email-Rendering.md §5.

/**
 * Parse any CSS color string to [r, g, b] using the browser's canvas engine.
 * Handles hex, rgb, rgba, hsl, hsla, named colors — every format the browser knows.
 * Returns null for invalid/unparseable colors.
 */
let _colorCtx
function parseColor(str) {
  if (!str) return null
  if (!_colorCtx) _colorCtx = document.createElement('canvas').getContext('2d')
  _colorCtx.fillStyle = '#808080' // sentinel — mid-gray, readable on both themes
  _colorCtx.fillStyle = str
  const val = _colorCtx.fillStyle
  if (val === '#808080') return null // didn't parse (or is mid-gray — fine either way)
  if (val.startsWith('#')) {
    return [parseInt(val.slice(1, 3), 16), parseInt(val.slice(3, 5), 16), parseInt(val.slice(5, 7), 16)]
  }
  const m = val.match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/)
  return m ? [parseInt(m[1]), parseInt(m[2]), parseInt(m[3])] : null
}

/** Perceived brightness (ITU-R BT.601). Range 0–255. */
function luma(r, g, b) { return r * 0.299 + g * 0.587 + b * 0.114 }

// DOMPurify config: a safe email profile. Drops <script>, event handlers and the
// remote-fetch / bypass tags emailprivacytester.com probes; <style> is removed so
// email CSS can't leak into the app or smuggle url() trackers.
const PURIFY_OPTS = {
  FORBID_TAGS: [...BLOCKED_TAGS, 'style'],
  FORBID_ATTR: BLOCKED_ATTR,
}

/**
 * Sanitize email HTML for readability on the current theme.
 * Uses DOM-based color rewriting so every color format is handled universally
 * — no regex whack-a-mole with hex, rgb, hsl, named colors, etc.
 *
 * Dark mode: strips dark text colors and light backgrounds.
 * Light mode: strips light text colors.
 * Preserves intentional accent colors (red, blue, green links/highlights).
 */
export function sanitizeEmailHtml(htmlStr, isDark) {
  if (!htmlStr) return htmlStr
  const clean = DOMPurify.sanitize(htmlStr, PURIFY_OPTS)
  const doc = new DOMParser().parseFromString(clean, 'text/html')

  for (const el of doc.body.querySelectorAll('*')) {
    // — Text color (inline style) —
    if (el.style.color) {
      const rgb = parseColor(el.style.color)
      if (rgb) {
        const l = luma(...rgb)
        if (isDark && l < 110 && Math.max(...rgb) < 160) {
          el.style.removeProperty('color')
        } else if (!isDark && l > 180) {
          el.style.removeProperty('color')
        }
      }
    }

    // — Text color (HTML attribute: <font color="...">) —
    if (el.hasAttribute('color')) {
      const rgb = parseColor(el.getAttribute('color'))
      if (rgb) {
        const l = luma(...rgb)
        if (isDark && l < 110 && Math.max(...rgb) < 160) {
          el.removeAttribute('color')
        } else if (!isDark && l > 180) {
          el.removeAttribute('color')
        }
      }
    }

    // — Background color (inline style) — strip light bgs in dark mode —
    if (isDark && el.style.backgroundColor) {
      const rgb = parseColor(el.style.backgroundColor)
      if (rgb && luma(...rgb) > 170) {
        el.style.removeProperty('background-color')
      }
    }

    // — Background color (HTML attribute: bgcolor="...") —
    if (isDark && el.hasAttribute('bgcolor')) {
      const rgb = parseColor(el.getAttribute('bgcolor'))
      if (rgb && luma(...rgb) > 170) {
        el.removeAttribute('bgcolor')
      }
    }
  }

  // Neutralize remote images/refs so opening the message phones home to nobody.
  const imgsBefore = doc.body.querySelectorAll('img').length
  const blocked = blockRemoteContent(doc.body)
  log.info('RemoteImages', `sanitize: imgs=${imgsBefore} blocked=${blocked}`)

  return doc.body.innerHTML
}
