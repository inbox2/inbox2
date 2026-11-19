// Email quoted text detector.
// Finds quoted sections in HTML email bodies and wraps them in a
// collapsible marker. Works with:
//   - Gmail (div.gmail_quote), Outlook (div#divRplyFwdMsg)
//   - Apple Mail / Thunderbird (blockquote[type=cite])
//   - Plain-text emails converted to HTML (-----Original Message-----, On X wrote:)
//
// Returns { content: string, hasQuote: boolean }

// ── HTML element selectors that mark quoted content ──────────
const QUOTE_SELECTORS = [
  'div.gmail_quote',
  'div.gmail_extra',
  'blockquote[type="cite"]',
  'div#divRplyFwdMsg',
  'div#appendonsend',
  'div#isForwardContent',
  'span.moz-cite-prefix',
]

// ── Outlook/Exchange header blocks ───────────────────────────
// The quoted original often carries no marker class and no
// "-----Original Message-----" divider — just a header block:
//   From: … / Sent: … / To: … / Cc: … / Subject: …
// Matched on an element (or line) whose text STARTS with From:, followed by at
// least two more header fields. Multilingual field names.
const HEADER_FROM = /^\s*(From|Van|De|Von|Da|Fra|Från)\s*:/i
const HEADER_FIELD =
  /\b(Sent|To|Cc|Subject|Date|Verzonden|Aan|Onderwerp|Gesendet|Betreff|Envoyé|Objet|Enviado|Para|Asunto|Inviato|Oggetto|Datum)\s*:/gi

/** Element text with <br>/block ends as newlines, so header fields stay separate lines. */
function blockText(el) {
  return el.innerHTML
    .replace(/<br\s*\/?>|<\/(p|div|tr|li|h\d)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
}

/** Does this text look like the start of a quoted-message header block? */
function isHeaderBlock(text) {
  if (!HEADER_FROM.test(text)) return false
  HEADER_FIELD.lastIndex = 0
  return (text.slice(0, 400).match(HEADER_FIELD) || []).length >= 2
}

// ── Line-level patterns for plain-text quotes ────────────────
// These match a line that starts a quoted/forwarded section.
// Used for plain-text emails that have been converted to HTML with <br> tags.
const LINE_QUOTE_PATTERNS = [
  /\s*-{4,}\s*Original Message\s*-{4,}/i,
  /\s*-{4,}\s*Forwarded message\s*-{4,}/i,
  /\s*-{4,}\s*Oorspronkelijk bericht\s*-{4,}/i,
  /\s*-{4,}\s*Message original\s*-{4,}/i,
  /\s*-{4,}\s*Ursprüngliche Nachricht\s*-{4,}/i,
  /^On .{10,120} wrote:\s*$/i,
  /^Le .{10,80} a écrit\s?:\s*$/i,
  /^Am .{10,80} schrieb .{3,40}:\s*$/i,
  /^Op .{10,80} schreef .{3,40}:\s*$/i,
  /^El .{10,80} escribió:\s*$/i,
  /^Em .{10,80} escreveu:\s*$/i,
  /^Il .{10,80} ha scritto:\s*$/i,
]

/**
 * Process an HTML email body: detect quoted blocks and wrap them
 * in a <div data-quoted-block> so the UI can collapse them.
 */
export function detectQuotes(html) {
  if (!html) return { content: html, hasQuote: false }

  // ── Strategy 1: Try HTML-structural detection first ────────
  try {
    const doc = new DOMParser().parseFromString(html, 'text/html')
    if (doc?.body) {
      // Known quote containers, else generic blockquotes
      let quotes = QUOTE_SELECTORS.flatMap((s) => [...doc.querySelectorAll(s)])
      if (!quotes.length) quotes = [...doc.querySelectorAll('blockquote')]

      // Unmarked "From: / Sent: / Subject:" header block (Strategy 1b)
      const header = [...doc.body.querySelectorAll('p, div, td, blockquote, table')]
        .find((el) => isHeaderBlock(blockText(el)))

      // The earliest quote start wins: an Outlook header block above a nested
      // blockquote/gmail_quote deeper in the quoted chain must not lose to it.
      const before = (q) => header.compareDocumentPosition(q) & header.DOCUMENT_POSITION_PRECEDING
      if (quotes.length && !(header && !quotes.some(before))) {
        for (const el of quotes) {
          if (el.closest('[data-quoted-block]')) continue
          wrapElement(el, doc)
        }
        return { content: doc.body.innerHTML, hasQuote: true }
      }

      // ── Strategy 1b: wrap the header block and everything after it ──
      for (const el of header ? [header] : []) {
        // ponytail: wraps the header and its following siblings only. If a client
        // nests the rest of the chain in an ancestor's later siblings, those stay
        // visible — walk the ancestor chain then.
        let start = el
        const prev = start.previousElementSibling
        if (prev && prev.tagName === 'HR') start = prev
        const wrapper = doc.createElement('div')
        wrapper.setAttribute('data-quoted-block', '')
        start.parentNode.insertBefore(wrapper, start)
        for (let n = wrapper.nextSibling; n; n = wrapper.nextSibling) wrapper.appendChild(n)
        return { content: doc.body.innerHTML, hasQuote: true }
      }
    }
  } catch {
    // Fall through to line-based detection
  }

  // ── Strategy 2: Line-based detection for plain-text HTML ───
  // Split on <br> tags (plain text emails converted to HTML)
  return detectByLine(html)
}

/**
 * Split HTML by <br> tags and find the line where a quote starts.
 * Everything from that line onward is wrapped in a quoted block.
 */
function detectByLine(html) {
  // Split on <br>, <br/>, <br /> — preserving the tag for reassembly
  const parts = html.split(/(<br\s*\/?>)/i)

  // Rebuild into logical lines (text between <br>s)
  const lines = []
  let current = ''
  for (const part of parts) {
    if (/<br\s*\/?>/i.test(part)) {
      lines.push({ text: stripTags(current).trim(), html: current + part })
      current = ''
    } else {
      current += part
    }
  }
  if (current) {
    lines.push({ text: stripTags(current).trim(), html: current })
  }

  // Find the first line that matches a quote pattern
  let quoteStart = -1
  for (let i = 0; i < lines.length; i++) {
    const text = lines[i].text
    if (!text) continue
    for (const pattern of LINE_QUOTE_PATTERNS) {
      if (pattern.test(text)) {
        quoteStart = i
        break
      }
    }
    // Header block spread over consecutive lines: From: … then Sent:/To:/Subject:
    if (quoteStart < 0 && isHeaderBlock(text + '\n' + lines.slice(i + 1, i + 6).map(l => l.text).join('\n'))) {
      quoteStart = i
    }
    if (quoteStart >= 0) break
  }

  if (quoteStart < 0) {
    return { content: html, hasQuote: false }
  }

  // Reassemble: before quote + wrapped quote block
  const before = lines.slice(0, quoteStart).map(l => l.html).join('')
  const quoted = lines.slice(quoteStart).map(l => l.html).join('')

  const content = `${before}<div data-quoted-block>${quoted}</div>`
  return { content, hasQuote: true }
}

/** Strip HTML tags from a string (for text matching). */
function stripTags(s) {
  return s.replace(/<[^>]+>/g, '')
}

/** Wrap a single element in a data-quoted-block div. */
function wrapElement(el, doc) {
  const wrapper = doc.createElement('div')
  wrapper.setAttribute('data-quoted-block', '')
  el.parentNode.insertBefore(wrapper, el)
  wrapper.appendChild(el)
}
