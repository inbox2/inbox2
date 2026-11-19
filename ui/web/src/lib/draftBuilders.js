// Pure helpers for building reply / forward draft bodies.
// Extracted from ConversationDetail so the same logic backs both the toolbar
// buttons and the keyboard shortcuts (useDraftActions).

export function plainTextToHtml(text) {
  if (!text) return '';
  const escaped = text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return escaped.replace(/\n/g, '<br>');
}

// Spacing is inline because mail clients reset stylesheet margins (Gmail
// forces p { margin: 0 }): a blank gap separates the quote block from the
// message text above it.
export function buildQuotedHtml(msg) {
  if (!msg) return '';
  const date = new Date(msg.created_at).toLocaleString();
  const body = msg.body_html || plainTextToHtml(msg.body_plain);
  return `<div class="quoted-message" style="margin: 16px 0 0"><p style="margin: 0 0 8px"><strong>On ${date}, ${msg.from_address} wrote:</strong></p><blockquote>${body}</blockquote></div>`;
}

export function buildForwardHtml(msg) {
  if (!msg) return '';
  const date = new Date(msg.created_at).toLocaleString();
  const body = msg.body_html || plainTextToHtml(msg.body_plain);
  return `<div class="forwarded-message" style="margin: 16px 0 0"><p style="margin: 0 0 8px">---------- Forwarded message ----------<br><strong>From:</strong> ${msg.from_address || ''}<br><strong>Date:</strong> ${date}<br><strong>Subject:</strong> ${msg.subject || ''}</p><blockquote>${body}</blockquote></div>`;
}

// Forward the entire conversation thread (oldest → newest), not just one message.
export function buildForwardChainHtml(conversation) {
  const msgs = conversation?.messages || [];
  if (msgs.length === 0) return '';
  const parts = msgs.map(msg => {
    const date = new Date(msg.created_at).toLocaleString();
    const body = msg.body_html || plainTextToHtml(msg.body_plain);
    return `<p style="margin: 0 0 8px"><strong>From:</strong> ${msg.from_address || ''}<br><strong>Date:</strong> ${date}<br><strong>To:</strong> ${msg.to_address || ''}<br><strong>Subject:</strong> ${msg.subject || conversation.subject || ''}</p><blockquote>${body}</blockquote>`;
  });
  return `<div class="forwarded-message" style="margin: 16px 0 0"><p style="margin: 0 0 8px">---------- Forwarded message ----------</p>${parts.join('<hr>')}</div>`;
}
