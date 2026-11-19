// Email signature detector.
// Finds signature sections in HTML email bodies and wraps them
// in a collapsible marker so the UI can collapse them.
//
// Works with:
//   - Gmail (div.gmail_signature, data-smartmail attribute)
//   - Outlook (div#Signature)
//   - Thunderbird (div.moz-signature)
//   - Apple Mail / generic (div.signature)
//   - Plain-text "-- " delimiter (RFC 3676)
//   - Heuristic contact blocks (Name + Phone/Mobile/Fax lines)
//
// Run AFTER detectQuotes() — this function skips [data-quoted-block]
// sections so only the current message's signature is detected.
//
// Returns { content: string, hasSignature: boolean }

// ── HTML element selectors that mark signature content ──────
const SIGNATURE_SELECTORS = [
  'div.gmail_signature',
  'div[data-smartmail="gmail_signature"]',
  'div#Signature',
  'div.moz-signature',
  'div.signature',
  'div.email-signature',
]

// Prefix elements some clients insert before the signature (e.g. "-- ")
const SIGNATURE_PREFIX_SELECTORS = [
  'div.gmail_signature_prefix',
  'span.gmail_signature_prefix',
]

// Standard email signature delimiter (RFC 3676: "-- " or common "-- " sans space)
const SIGNATURE_LINE_PATTERN = /^--\s?$/

// Signature blocks longer than this (in non-empty lines) are probably not
// signatures — avoids false positives on "-- " in prose or code.
const MAX_SIGNATURE_LINES = 12

// Contact-info line patterns for heuristic detection (no "-- " delimiter)
const CONTACT_LINE_PATTERN = /^(Phone|Mobile|Cell|Fax|Tel|Telephone|Office|Direct|Work|Home)\s*[:.]?\s*[\d(+]/i

// Bare phone number on its own line (no label prefix).
// Matches 7+ digit strings with common separators: 713-853-3465, (713) 853-3465, +1 713.853.3465
const BARE_PHONE_PATTERN = /^\+?[(]?[\d][\d\s()._-]{6,}$/

/**
 * Detect email signatures in an HTML body and wrap them in
 * <div data-signature-block>. Skips content inside [data-quoted-block].
 */
export function detectSignatures(html) {
  if (!html) return { content: html, hasSignature: false }

  // ── Strategy 1: HTML-structural detection ─────────────────
  try {
    const doc = new DOMParser().parseFromString(html, 'text/html')
    if (doc?.body) {
      let found = false

      for (const selector of SIGNATURE_SELECTORS) {
        for (const el of doc.querySelectorAll(selector)) {
          if (el.closest('[data-signature-block]')) continue
          if (el.closest('[data-quoted-block]')) continue
          wrapWithPrefix(el, doc)
          found = true
        }
      }

      if (found) {
        return { content: doc.body.innerHTML, hasSignature: true }
      }
    }
  } catch {
    // Fall through to line-based detection
  }

  // ── Strategy 2: Line-based "-- " delimiter ────────────────
  return detectSignatureByLine(html)
}

/**
 * Wrap a signature element in a data-signature-block div.
 * If the previous sibling is a known prefix element (e.g. Gmail's "-- " div),
 * include it in the same wrapper so the whole block collapses together.
 */
function wrapWithPrefix(el, doc) {
  const wrapper = doc.createElement('div')
  wrapper.setAttribute('data-signature-block', '')

  const prev = el.previousElementSibling
  if (prev) {
    const isPrefix = SIGNATURE_PREFIX_SELECTORS.some(sel => prev.matches?.(sel))
    if (isPrefix) {
      prev.parentNode.insertBefore(wrapper, prev)
      wrapper.appendChild(prev)
      wrapper.appendChild(el)
      return
    }
  }

  el.parentNode.insertBefore(wrapper, el)
  wrapper.appendChild(el)
}

/**
 * Line-based detection for plain-text emails (converted to HTML with <br>).
 * Strategy 2: "-- " delimiter — wraps everything from delimiter to end.
 * Strategy 3: Contact-block heuristic — wraps just the name+contact lines.
 */
function detectSignatureByLine(html) {
  // Separate any trailing data-quoted-block so we only scan the main body
  const quotedBlockRe = /<div data-quoted-block[\s\S]*$/
  const match = quotedBlockRe.exec(html)
  const mainHtml = match ? html.slice(0, match.index) : html
  const trailingHtml = match ? match[0] : ''

  const lines = splitLines(mainHtml)

  // ── Strategy 2: "-- " delimiter ───────────────────────────
  const delimResult = detectByDelimiter(lines, trailingHtml)
  if (delimResult) return delimResult

  // ── Strategy 3: Contact-block heuristic ───────────────────
  const contactResult = detectContactBlock(lines, trailingHtml)
  if (contactResult) return contactResult

  return { content: html, hasSignature: false }
}

/** Split HTML by <br> tags into logical lines. */
function splitLines(html) {
  const parts = html.split(/(<br\s*\/?>)/i)
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
  return lines
}

/** Strategy 2: Find "-- " delimiter and wrap everything after it. */
function detectByDelimiter(lines, trailingHtml) {
  for (let i = 0; i < lines.length; i++) {
    if (SIGNATURE_LINE_PATTERN.test(lines[i].text)) {
      const remaining = lines.slice(i + 1).filter(l => l.text.length > 0)
      if (remaining.length <= MAX_SIGNATURE_LINES && i > 0) {
        const before = lines.slice(0, i).map(l => l.html).join('')
        const sig = lines.slice(i).map(l => l.html).join('')
        return { content: `${before}<div data-signature-block>${sig}</div>${trailingHtml}`, hasSignature: true }
      }
      break
    }
  }
  return null
}

/** Returns true if a line looks like contact info (labeled or bare phone). */
function isContactLine(text) {
  return CONTACT_LINE_PATTERN.test(text) || BARE_PHONE_PATTERN.test(text)
}

/**
 * Returns true if a line could be part of a signature header: a name,
 * company, title, or sign-off like "Thanks,". Must be short and have
 * few words to avoid matching body prose.
 */
function isSignatureLabel(text) {
  return text.length > 0 && text.length < 40 && text.split(/\s+/).length <= 4 && !/\d/.test(text)
}

/**
 * Strategy 3: Detect a contact block near the end of the email.
 * Handles patterns like:
 *   Name                      Name
 *   Phone: 713-853-6460       CompanyName
 *   Mobile: 832-264-6333      713-853-3465
 *
 * Scans backwards from the end. Walks up through contact lines, then through
 * short non-contact lines (company/title), looking for a name line at the top.
 * Wraps only the signature block so content after it is preserved.
 */
function detectContactBlock(lines, trailingHtml) {
  // Find the last non-empty line to start scanning from
  let scanEnd = lines.length - 1
  while (scanEnd > 0 && !lines[scanEnd].text) scanEnd--

  // Scan backwards to find consecutive contact lines (labeled or bare phone)
  let contactEnd = -1
  let contactStart = -1
  for (let i = scanEnd; i >= 0; i--) {
    if (isContactLine(lines[i].text)) {
      if (contactEnd === -1) contactEnd = i
      contactStart = i
    } else if (contactEnd !== -1) {
      break
    }
  }

  // Need at least one contact line
  if (contactStart < 0) return null

  // Walk upwards from contactStart looking for title/company lines and a name.
  // Allow up to 3 short non-contact, non-empty lines (title, dept, company)
  // between the name and the phone numbers.
  let blockStart = contactStart
  let idx = contactStart - 1
  let extras = 0
  // Skip blanks
  while (idx > 0 && !lines[idx].text) idx--
  // Absorb short intermediate lines (company, title, etc.)
  while (idx > 0 && extras < 3) {
    const text = lines[idx].text
    if (!text) { idx--; continue }
    if (isSignatureLabel(text)) {
      blockStart = idx
      extras++
      idx--
      // Skip blanks before trying another line
      while (idx > 0 && !lines[idx].text) idx--
    } else {
      break
    }
  }

  // The topmost line of the block must look like a name (no digits)
  if (!isSignatureLabel(lines[blockStart].text)) return null

  // Must not start at line 0 (would wrap entire message)
  if (blockStart <= 0) return null

  // Include any blank lines between body and signature start
  let wrapStart = blockStart
  while (wrapStart > 1 && !lines[wrapStart - 1].text) wrapStart--

  const before = lines.slice(0, wrapStart).map(l => l.html).join('')
  const sig = lines.slice(wrapStart, contactEnd + 1).map(l => l.html).join('')
  const after = lines.slice(contactEnd + 1).map(l => l.html).join('')
  return { content: `${before}<div data-signature-block>${sig}</div>${after}${trailingHtml}`, hasSignature: true }
}

/** Strip HTML tags from a string (for text matching). */
function stripTags(s) {
  return s.replace(/<[^>]+>/g, '')
}
