// @inbox2/email-body — framework-free email body processing.
//
// Quote/signature collapsing and remote-image privacy, with NO dependency on
// React, the app, or any framework — only the browser DOM it runs in. Shared by
// the web app's desktop iframe and (bundled) by the native iOS/Android WebViews,
// so all platforms collapse quotes, detect signatures, and block remote images
// identically.

export { detectQuotes } from './quoteDetector.js';
export { detectSignatures } from './signatureDetector.js';
export {
  blockRemoteContent,
  PLACEHOLDER,
  BLOCKED_TAGS,
  BLOCKED_ATTR,
} from './blockRemoteContent.js';
export { shouldProxyImages } from './imagePolicy.js';
export { unwrapWrappedHtml } from './unwrapWrappedHtml.js';
export { bodyIsForwardOnly } from './forwardOnly.js';

import { detectQuotes } from './quoteDetector.js';
import { detectSignatures } from './signatureDetector.js';
import { blockRemoteContent } from './blockRemoteContent.js';
import { unwrapWrappedHtml } from './unwrapWrappedHtml.js';
import { bodyIsForwardOnly } from './forwardOnly.js';

/**
 * Run the full body pipeline on an HTML string: unwrap a <pre>-wrapped document,
 * block remote content, then mark quoted-reply and signature blocks (quotes
 * first, so signature detection skips what's inside a quote). Returns the marked
 * HTML plus what was found. The host decides how to render the marked blocks (the
 * web iframe wraps them in `<details>`; React extracts them into `···` toggles).
 *
 * Used by the native iOS/Android WebViews; the web desktop iframe runs the same
 * steps individually in EmailFrame.buildSrcDoc.
 *
 * @param {string} html  sanitized email body HTML
 * @param {{ block?: boolean }} [opts]  block remote content first (default true)
 * @returns {{ html: string, hasQuote: boolean, hasSignature: boolean, quotesOnly: boolean, blockedCount: number }}
 */
export function processBody(html, opts = {}) {
  const { block = true } = opts;
  let blockedCount = 0;

  // Always parse: unwrap a <pre>-wrapped HTML document (else `white-space:pre`
  // blows the layout out to thousands of px wide), then optionally block remote
  // content on the same tree.
  const doc = new DOMParser().parseFromString(html, 'text/html');
  unwrapWrappedHtml(doc.body);
  if (block) {
    blockedCount = blockRemoteContent(doc.body);
  }
  const working = doc.body.innerHTML;

  const q = detectQuotes(working);
  const s = detectSignatures(q.content);
  return {
    html: s.content,
    hasQuote: q.hasQuote,
    hasSignature: s.hasSignature,
    // A bare forward (only a quoted block, no added note) — hosts auto-expand it.
    quotesOnly: q.hasQuote && bodyIsForwardOnly(s.content),
    blockedCount,
  };
}
