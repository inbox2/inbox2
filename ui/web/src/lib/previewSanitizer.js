// Sanitizer for the outgoing-draft preview (PreviewPane). This previews the
// user's OWN draft, so remote images are not blocked here — only sanitized.
// The tracking-pixel defence lives on the received-mail render path
// (MessageCard/QuotedText + useRemoteImages).

import createDOMPurify from 'dompurify'
import { BLOCKED_ATTR } from '@inbox2/email-body'

const SANITIZE_OPTS = {
  ALLOWED_TAGS: [
    // `b`/`i` are not aliases DOMPurify normalises — omitting them silently
    // unbolds every Outlook/Gmail quote (the tag goes, its text stays).
    'p', 'br', 'strong', 'b', 'em', 'i', 'u', 's', 'a', 'img', 'sub', 'sup',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'ul', 'ol', 'li', 'blockquote', 'pre', 'code',
    'hr', 'table', 'thead', 'tbody', 'tr', 'th', 'td',
    'div', 'span',
  ],
  ALLOWED_ATTR: ['href', 'src', 'alt', 'title', 'target', 'rel', 'class', 'style'],
  FORBID_ATTR: BLOCKED_ATTR,
}

// Inline-style properties allowed through to the preview. Outlook/OWA mail
// carries ALL of its paragraph spacing as inline margins (`<div
// style="margin-top:1em ...">` per paragraph) — stripping `style` wholesale
// collapses the quoted thread into a wall of single-spaced lines. Same story
// for emphasis: Word-generated mail bolds via `style="font-weight:bold"`, not
// `<strong>`. Keep layout + emphasis; colors, font-family and font-size stay
// stripped so received content can't paint e.g. black-on-dark text into the
// themed preview.
const SAFE_STYLE_PROPS = new Set([
  'margin', 'margin-top', 'margin-bottom', 'margin-left', 'margin-right',
  'padding', 'padding-top', 'padding-bottom', 'padding-left', 'padding-right',
  'font-weight', 'font-style', 'text-decoration', 'text-align',
])

export function filterInlineStyle(style) {
  return style
    .split(';')
    .map(decl => {
      const i = decl.indexOf(':')
      if (i <= 0) return null
      return [decl.slice(0, i).trim().toLowerCase(), decl.slice(i + 1).trim()]
    })
    .filter(d => d && SAFE_STYLE_PROPS.has(d[0]) && !/url\s*\(/i.test(d[1]))
    .map(([prop, value]) => `${prop}: ${value}`)
    .join('; ')
}

// Own DOMPurify instance: the style-filtering hook must not leak into the
// other sanitize call sites (EmailFrame keeps full email styles, for one).
const purifier = createDOMPurify(window)
purifier.addHook('afterSanitizeAttributes', (node) => {
  if (!node.hasAttribute?.('style')) return
  const kept = filterInlineStyle(node.getAttribute('style'))
  if (kept) node.setAttribute('style', kept)
  else node.removeAttribute('style')
})

export function sanitizePreviewHtml(html) {
  return purifier.sanitize(html, SANITIZE_OPTS)
}
