import { useState, useMemo } from 'react'
import { detectQuotes, detectSignatures } from '@inbox2/email-body'
import { THEME_MODE } from '../../lib/themes'
import { sanitizeEmailHtml } from './sanitizeEmailHtml'
import styles from './QuotedText.module.css'

// Lines that introduce/label a forward but aren't real body content: the
// forward intro and the quoted From/Subject/Date/To/Cc headers Apple Mail and
// Gmail emit. If the body holds only these, the forward has no added note.
const FORWARD_NOISE = /^(begin forwarded message:?|-+\s*forwarded message\s*-+|(from|to|cc|bcc|date|sent|subject|reply-to)\s*:.*)$/i

export default function QuotedText({ html }) {
  const isDark = document.documentElement.getAttribute('data-theme') !== THEME_MODE.LIGHT
  const [quotesExpanded, setQuotesExpanded] = useState(null) // null = auto-detect
  const [signatureExpanded, setSignatureExpanded] = useState(false)

  const sanitizedHtml = useMemo(() => sanitizeEmailHtml(html, isDark), [html, isDark])

  const { hasQuote, hasSignature, bodyHtml, signatureHtml, quotedHtml } = useMemo(() => {
    try {
      // Detect quotes first, then signatures in the remaining body
      const quoteResult = detectQuotes(sanitizedHtml)
      const sigResult = detectSignatures(quoteResult.content)

      const doc = new DOMParser().parseFromString(sigResult.content, 'text/html')

      // Extract signature blocks
      let sigHtml = ''
      for (const s of doc.querySelectorAll('[data-signature-block]')) {
        sigHtml += s.innerHTML
        s.remove()
      }

      // Extract quoted blocks
      let qHtml = ''
      for (const q of doc.querySelectorAll('[data-quoted-block]')) {
        qHtml += q.innerHTML
        q.remove()
      }

      return {
        hasQuote: quoteResult.hasQuote,
        hasSignature: sigResult.hasSignature,
        bodyHtml: doc.body.innerHTML,
        signatureHtml: sigHtml,
        quotedHtml: qHtml,
      }
    } catch {
      return {
        hasQuote: false,
        hasSignature: false,
        bodyHtml: sanitizedHtml,
        signatureHtml: '',
        quotedHtml: '',
      }
    }
  }, [sanitizedHtml])

  // Auto-expand quotes if the body has no real user-added text — i.e. the
  // message is just a forward. The leftover body of a forward isn't empty: it
  // holds the forward intro ("Begin forwarded message:") and the forwarded
  // From/Subject/Date/To headers. Those aren't content, so we strip them and,
  // if nothing meaningful remains, keep the forwarded body expanded.
  const bodyText = (bodyHtml || '')
    .replace(/<(br|\/p|\/div|\/li|\/tr|\/h[1-6])\s*\/?>/gi, '\n')
    .replace(/<[^>]*>/g, '')
    .trim()
  const bodyIsEmpty = bodyText
    .split('\n')
    .map(l => l.trim())
    .every(l => !l || /^[-–—]+$/.test(l) || FORWARD_NOISE.test(l))
  const showQuotes = quotesExpanded === null ? (hasQuote && bodyIsEmpty) : quotesExpanded

  if (!hasQuote && !hasSignature) {
    return <div dangerouslySetInnerHTML={{ __html: sanitizedHtml }} />
  }

  return (
    <div>
      <div dangerouslySetInnerHTML={{ __html: bodyHtml }} />
      {hasSignature && (
        <>
          <button
            className={`${styles.toggle} ${signatureExpanded ? styles.toggleExpanded : ''}`}
            onClick={() => setSignatureExpanded(v => !v)}
            title={signatureExpanded ? 'Hide signature' : 'Show signature'}
          >
            {signatureExpanded ? '—' : '···'}
          </button>
          {signatureExpanded && (
            <div className={styles.signatureBlock} dangerouslySetInnerHTML={{ __html: signatureHtml }} />
          )}
        </>
      )}
      {hasQuote && (
        <>
          <button
            className={`${styles.toggle} ${showQuotes ? styles.toggleExpanded : ''}`}
            onClick={() => setQuotesExpanded(v => v === null ? !bodyIsEmpty : !v)}
            title={showQuotes ? 'Hide quoted text' : 'Show quoted text'}
          >
            {showQuotes ? '—' : '···'}
          </button>
          {showQuotes && (
            <div dangerouslySetInnerHTML={{ __html: quotedHtml }} />
          )}
        </>
      )}
    </div>
  )
}
