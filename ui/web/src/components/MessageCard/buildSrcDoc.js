import DOMPurify from 'dompurify'
import {
  detectQuotes,
  detectSignatures,
  blockRemoteContent,
  unwrapWrappedHtml,
  bodyIsForwardOnly,
  BLOCKED_TAGS,
  BLOCKED_ATTR,
} from '@inbox2/email-body'

// The iframe document builder for HTML emails, extracted from EmailFrame so it can
// be unit-tested in isolation (emailRendering.test.jsx) without rendering the React
// component. EmailFrame imports buildSrcDoc and feeds the result to the <iframe
// srcDoc>. See docs/Email-Rendering.md §2.1.

// Keep <style> and layout; strip scripts, remote-fetch and bypass tags.
const PURIFY_OPTS = { FORBID_TAGS: BLOCKED_TAGS, FORBID_ATTR: BLOCKED_ATTR }

// Injected into the email document: reset margins, render on the white "page"
// emails assume, and style the native <details> we use to collapse quotes/sigs.
const BASE_CSS = `
  html,body{margin:0;padding:0;background:#fff;}
  body{font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#1a1a1a;word-break:break-word;padding:16px;}
  img{max-width:100%;}
  a{color:#1a73e8;}
  details{margin:8px 0;}
  details>summary{cursor:pointer;color:#5f6368;font-size:12px;list-style:none;padding:2px 6px;border-radius:4px;display:inline-block;background:#f1f3f4;user-select:none;}
  details>summary::-webkit-details-marker{display:none;}
`

// Injected as the LAST stylesheet in the document so it wins the cascade over
// the email's own !important rules. Two correctness fixes for iframe auto-height:
//
//  1. height:auto — many templates (TikTok, marketing/notification) set
//     `html,body{height:100% !important}`. That pins body to the iframe's
//     default 150px viewport, so body.scrollHeight reports 150 and the frame is
//     clipped to a short white box no matter how tall the real content is.
//  2. display:flow-root — TikTok wraps its entire body in a `float:left`
//     element. A floated child doesn't contribute to its parent's height, so
//     the body collapses and (in WebKit/WKWebView especially) scrollHeight
//     misses the floated content. flow-root makes body a block formatting
//     context that contains the float, so scrollHeight measures true content.
//
// Verified under Playwright's WebKit (the app's WKWebView engine): this email
// goes from a clipped 150px frame to the correct 776px.
const FRAME_FIT_CSS = `
  html,body{height:auto!important;min-height:0!important;}
  body{display:flow-root!important;}
`

// Replace remote url() inside email <style> blocks (CSS background trackers) and
// drop @import — we can't proxy CSS-rule images, so neutralize them for privacy.
// Inline background-images are handled separately (stashed + proxied).
function sanitizeStyleSheets(doc) {
  for (const styleEl of doc.querySelectorAll('style')) {
    styleEl.textContent = styleEl.textContent
      .replace(/@import[^;]+;/gi, '')
      .replace(/url\(\s*(['"]?)(https?:)?\/\/[^'")]+\1\s*\)/gi, 'none')
  }
}

function collapseBlocks(doc, selector, summaryLabel, open) {
  for (const el of doc.querySelectorAll(selector)) {
    const details = doc.createElement('details')
    if (open) details.setAttribute('open', '')
    const summary = doc.createElement('summary')
    summary.textContent = summaryLabel
    details.appendChild(summary)
    while (el.firstChild) details.appendChild(el.firstChild)
    el.replaceWith(details)
  }
}

// The iframe's hard backstop: ALL remote loads are forbidden — only our proxied
// blob: images (and inline data:) render, so no email vector (SVG, CSS-escape,
// video, newline-src, fonts…) can ever phone home. The single exception is the
// consented direct render (`direct`): some image hosts sit behind bot management
// that 403s any server-side fetch, so after an explicit "Load directly" click the
// CSP admits https/http images and the proxy-refused ones load from the reader.
function cspMeta(direct) {
  const imgSrc = direct ? 'data: blob: https: http:' : 'data: blob:'
  const csp = `default-src 'none'; img-src ${imgSrc}; style-src 'unsafe-inline'; font-src data:; media-src 'none'`
  return `<meta http-equiv="Content-Security-Policy" content="${csp}">`
}

// True when a CSS color is effectively white (every channel ≥ 236). A background
// this light is visually indistinguishable from the app's white reading page, so an
// email that merely paints itself white must NOT be treated as a self-styled,
// full-bleed design — it still needs reading padding, or prose runs flush against
// the card edges. Only genuinely colored / image backgrounds count as full-bleed.
// Mirrors the iOS reader's nearWhite() guard (MessageBodyWebView).
export function isNearWhite(color) {
  if (!color) return false
  const c = String(color).trim().toLowerCase()
  if (c === 'white' || c === '#fff' || c === '#ffffff') return true
  const m = c.match(/(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/)
  if (!m) return false
  return +m[1] >= 236 && +m[2] >= 236 && +m[3] >= 236
}

export function buildSrcDoc(html, direct, tauri = false) {
  const clean = DOMPurify.sanitize(html, PURIFY_OPTS)
  const doc = new DOMParser().parseFromString(clean, 'text/html')

  // Some senders wrap their whole HTML email in a <pre>; its `white-space:pre`
  // blows the layout out to thousands of px wide (content ends up off-screen).
  // Unwrap it before anything else so the rest of the pipeline sees normal HTML.
  unwrapWrappedHtml(doc.body)
  sanitizeStyleSheets(doc)
  blockRemoteContent(doc.body)

  // Detect quoted text + signature, then collapse each into a native <details>.
  const q = detectQuotes(doc.body.innerHTML)
  const s = detectSignatures(q.content)
  const split = new DOMParser().parseFromString(s.content, 'text/html')

  // Auto-expand the quote when the message is just a forward (no real body text).
  const bodyEmpty = bodyIsForwardOnly(s.content)

  collapseBlocks(split, '[data-signature-block]', 'Signature', false)
  collapseBlocks(split, '[data-quoted-block]', 'Quoted text', bodyEmpty)

  // dir="auto" gives the document a base direction taken from its first strong
  // character, so an Arabic or Hebrew mail whose own markup omits `dir` (most of
  // them) renders right-aligned with its punctuation in the right place instead
  // of left-aligned LTR.
  return '<!doctype html><html dir="auto"><head><meta charset="utf-8">'
    + cspMeta(direct)
    + '<meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<meta http-equiv="x-dns-prefetch-control" content="off">'
    // Link opening differs by host, because WebKit (Safari + desktop WKWebView)
    // never delivers a sandboxed-iframe click to the parent's JS handler:
    //   - Web: <base target="_blank"> opens a real tab natively. The sandbox must
    //     include allow-popups (EmailFrame) or WebKit silently blocks it.
    //   - Desktop (Tauri): NO base target, so the click is an in-frame navigation
    //     — which the Rust email-link-router (on_navigation) intercepts, cancels,
    //     and hands to the OS default browser (a proper system-level open).
    //     target="_blank" would route to WKWebView's createWebView (a popup Tauri
    //     doesn't intercept), so the link would silently do nothing.
    + (tauri ? '' : '<base target="_blank">')
    // FRAME_FIT_CSS goes LAST (after the email's own <style> blocks) so its
    // !important height/flow-root rules win the cascade and the iframe auto-sizes.
    + `<style>${BASE_CSS}</style></head><body>${split.body.innerHTML}<style>${FRAME_FIT_CSS}</style></body></html>`
}
