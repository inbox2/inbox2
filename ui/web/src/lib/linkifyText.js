// Render a plain-text email body as HTML with bare URLs turned into clickable
// links (plain text has no <a> tags, so links would otherwise be inert). The
// resulting anchors are intercepted by the message body's click handler and
// routed through openLink, exactly like links in HTML emails.

// Quotes too: the URL lands inside href="…", and a received link carrying a `"`
// would otherwise close the attribute and add its own (onmouseover=…).
function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// http(s):// URLs and bare www. hosts. Stops at whitespace or '<'.
const URL_RE = /\b(https?:\/\/[^\s<]+|www\.[^\s<]+)/gi;

export function linkifyText(text) {
  if (!text) return '';

  let out = '';
  let last = 0;
  let m;
  URL_RE.lastIndex = 0;
  while ((m = URL_RE.exec(text)) !== null) {
    out += escapeHtml(text.slice(last, m.index));

    // Don't swallow trailing sentence punctuation into the link.
    let url = m[0];
    const trail = url.match(/[.,;:!?)\]]+$/);
    let suffix = '';
    if (trail) {
      suffix = url.slice(url.length - trail[0].length);
      url = url.slice(0, url.length - trail[0].length);
    }

    const href = url.startsWith('www.') ? `https://${url}` : url;
    out += `<a href="${escapeHtml(href)}">${escapeHtml(url)}</a>${escapeHtml(suffix)}`;
    last = m.index + m[0].length;
  }
  out += escapeHtml(text.slice(last));

  return out.replace(/\n/g, '<br>');
}
