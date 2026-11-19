// Editor HTML → email HTML.
//
// TipTap's serialized HTML relies on two things that don't survive outside
// the editor:
//   1. Blank lines the user types serialize as `<p></p>`, which renders
//      zero-height everywhere else — the editor only shows them because
//      ProseMirror keeps a trailing <br> in its live DOM.
//   2. Paragraph spacing comes from the editor stylesheet, and mail clients
//      reset it (Gmail forces p { margin: 0 }).
// Make blank lines real and inline the editor's paragraph rhythm, so the
// preview pane and the recipient both see what the composer showed.

// Bottom margin matching the editor's `p { margin: 0 0 var(--space-2) }`.
const PARAGRAPH_MARGIN = '0 0 8px'

export function editorHtmlToEmailHtml(html) {
  if (!html) return ''
  const doc = new DOMParser().parseFromString(html, 'text/html')
  for (const p of doc.body.querySelectorAll('p')) {
    if (!p.firstChild) p.appendChild(doc.createElement('br'))
    p.style.margin = PARAGRAPH_MARGIN
  }
  return doc.body.innerHTML
}
