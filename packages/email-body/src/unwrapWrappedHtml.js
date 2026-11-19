// Some senders deliver their entire HTML email wrapped inside a <pre> — the
// part arrives as `<pre><!doctype html><html>…<table>…</table></html></pre>`.
// The browser parses the inner tags as real elements (so the email "kind of"
// renders), but <pre>'s default `white-space: pre` stops the layout from
// wrapping: the document lays out thousands of pixels wide and most of its
// content sits off-screen. Gmail's sanitizer strips this wrapper; we must too.
//
// We only unwrap a <pre> that actually wraps STRUCTURAL html (a table/img/div/
// center) — never a genuine preformatted code/text block, which contains only
// text. Mutates the root in place; returns the number of <pre>s unwrapped.

const STRUCTURAL = 'table, img, div, center, tbody, tr, td';

export function unwrapWrappedHtml(root) {
  if (!root) return 0;
  let unwrapped = 0;
  // Snapshot first: unwrapping mutates the tree we'd otherwise be iterating.
  for (const pre of Array.from(root.querySelectorAll('pre'))) {
    if (!pre.querySelector(STRUCTURAL)) continue; // real preformatted text — leave it
    // Replace the <pre> with its children so they render in a normal block
    // context (wrapping, constrained to the viewport width).
    pre.replaceWith(...pre.childNodes);
    unwrapped++;
  }
  return unwrapped;
}
