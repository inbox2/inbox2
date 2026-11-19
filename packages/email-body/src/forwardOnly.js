// "Bare forward" detection.
//
// When a message is forwarded as-is — the forwarder added no note of their own —
// the entire visible content is the quoted/forwarded block. With the quote
// collapsed behind a toggle, such a message renders as a blank card. So every host
// (web/desktop iframe + native iOS/Android WebViews) auto-expands the quote in this
// one case, instead of showing an empty body above a "Quoted text" pill.
//
// `markedHtml` is the body AFTER detectQuotes/detectSignatures have wrapped the
// quoted reply and signature in [data-quoted-block]/[data-signature-block]. We
// remove those blocks and check whether any real text remains outside them.
export function bodyIsForwardOnly(markedHtml) {
  try {
    const doc = new DOMParser().parseFromString(markedHtml || '', 'text/html');
    doc.body
      .querySelectorAll('[data-quoted-block],[data-signature-block]')
      .forEach((n) => n.remove());
    return doc.body.textContent.replace(/\s+/g, ' ').trim().length === 0;
  } catch {
    return false;
  }
}
