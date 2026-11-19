// Derive the best plain-text representation of a message body.
// Many messages carry their body in `body_html` with an empty `body_plain`,
// so prefer the HTML body (stripped of tags) and fall back to plain text.
// Used for AI classification/summarization input and previews.

/**
 * Strip HTML tags, returning the rendered text content.
 * @param {string} html
 * @returns {string}
 */
export function stripHtml(html) {
  if (!html) return '';
  // DOMParser yields an INERT document: unlike setting innerHTML on a live/detached
  // element, it neither runs scripts nor loads resources, so untrusted email HTML
  // can't fire `<img onerror=…>` in the app origin while we extract its text.
  const body = new DOMParser().parseFromString(html, 'text/html').body;
  // Drop non-content elements whose text would otherwise leak into the output.
  // Word/Outlook emit large <style> blocks (CSS wrapped in <!-- -->) that would
  // otherwise appear verbatim in previews and AI classification input.
  body.querySelectorAll('style, script, head, title, noscript').forEach(el => el.remove());
  // textContent concatenates adjacent block elements with no separator, mashing
  // words together ("TesterEmail"). Insert a space at block boundaries and a
  // newline for <br> so previews and AI input read as separate words/lines.
  body.querySelectorAll('br').forEach(el => el.replaceWith('\n'));
  body.querySelectorAll(
    'p, div, li, tr, td, h1, h2, h3, h4, h5, h6, blockquote, section, article, header, footer, pre, ul, ol, table'
  ).forEach(el => el.append(' '));
  return body.textContent || '';
}

/**
 * Best plain-text body for a message: stripped HTML, else plain text.
 * @param {{body_html?: string, body_plain?: string}|null} message
 * @returns {string}
 */
export function messagePlainText(message) {
  if (!message) return '';
  const fromHtml = stripHtml(message.body_html).trim();
  if (fromHtml) return fromHtml;
  return (message.body_plain || '').trim();
}
