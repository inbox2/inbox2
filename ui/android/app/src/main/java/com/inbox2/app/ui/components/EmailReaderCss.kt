package com.inbox2.app.ui.components

/**
 * The CSS + scale-to-fit JS the email reader injects around an email body before
 * rendering it in the WebView — the Android counterpart of iOS `EmailReaderCSS`.
 *
 * Strategy: **reflow, and scale only what refuses to reflow** — Gmail's mobile behaviour.
 * Text containers wrap into the phone column at full size; the elements whose width IS
 * their design (a table, a wide image, a `<pre>`) can't wrap without being destroyed, so
 * those alone are scaled down to fit. A 600px MJML marketing email is one such table and
 * scales as a whole; a business thread with prose plus one 1600px quoted table keeps its
 * prose readable and shrinks only the table. Scaling the whole body — the previous
 * strategy — took such a thread down to ~0.2 and made all of it an unreadable thumbnail.
 */
internal object EmailReaderCss {
    /** Height backstop, injected as the LAST stylesheet so its !important rules win:
     *  templates that set `html,body{height:100%}` (PayPal receipts, MJML) would
     *  otherwise clamp the measured document height to the WebView frame and collapse
     *  the body to a sliver. Mirrors iOS `EmailReaderCSS.fitBackstopCss` + the desktop
     *  iframe's FRAME_FIT_CSS. */
    const val FIT_BACKSTOP_CSS = "html,body{height:auto!important;min-height:0!important;}body{display:flow-root!important;}"

    const val CSS = """
          /* Default to a WHITE canvas with dark text (matching the desktop iframe):
             real-world HTML emails ship their own dark-text-on-light styling and assume
             a white background. The detection script below drops back to transparent —
             letting the dark app surface show through — only when the email paints its
             own background, so fully-styled (incl. dark) emails still render correctly. */
          html, body { margin: 0; overflow-x: hidden; background: #ffffff; }
          body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; padding: 4px 16px 8px; color: #1a1a1a; word-break: break-word; }
          /* NOTE: no blanket `max-width:100%` on everything — that would squeeze a 600px
             MJML design into the column and wreck it. The fit JS reflows per element and
             scales only what can't reflow; #body clips the leftover layout box of anything
             it scaled (a transform shrinks the paint, not the layout width). */
          #body { overflow-x: hidden; }
          #body td, #body th { word-break: break-word; }
          img { max-width: 100%; height: auto; }
          [data-quoted-block], [data-signature-block] { color: #5f6368; }
          details { margin-top: 12px; }
          summary { color: #1a73e8; cursor: pointer; list-style: none; padding: 4px 0; }
          a { color: #1a73e8; }
          blockquote { border-left: 3px solid #dadce0; margin: 8px 0; padding-left: 12px; }
    """

    /**
     * Defines `window.__fitEmail()` — the per-element fit pass (iOS `EmailReaderCSS.fitJS`;
     * keep the two identical). Walks down from `#body` into whatever overflows the column
     * and takes the first option that works: (1) it already fits — leave it, which is why
     * ordinary prose is never shrunk; (2) a descendant is the wide one — recurse, so we
     * reach the wide table itself and not the wrapper holding it plus pages of prose;
     * (3) its own box is too wide — reflow it with `max-width:100%`; (4) it can't reflow
     * (table/img/pre — width IS the design) or still doesn't fit — scale that element
     * alone. A transform shrinks paint, not layout, so the leftover layout height is
     * pulled back with a negative margin-bottom and the document height stays true.
     *
     * Overflow is measured at the real column width — NOT via `width: max-content`, which
     * lays every block out on one non-wrapping line and reports a bogus width of thousands
     * of px for ordinary prose. Idempotent: each run undoes the previous one first.
     */
    const val FIT_JS = """
      var FIT_ATOMIC = 'table,img,pre,svg,video,canvas,iframe,object,figure';
      window.__fitEmail = function () {
        var root = document.getElementById('body');
        if (!root) return 1;
        var avail = root.clientWidth;
        if (!avail) return 1;
        var prev = root.querySelectorAll('[data-fit]');
        for (var i = 0; i < prev.length; i++) {
          var e = prev[i];
          e.style.transform = ''; e.style.transformOrigin = '';
          e.style.marginBottom = e.dataset.fitMb || '';
          e.style.maxWidth = e.dataset.fitMw || '';
          e.removeAttribute('data-fit'); delete e.dataset.fitMb; delete e.dataset.fitMw;
        }
        var minScale = 1;
        function width(el) { return Math.max(el.scrollWidth, Math.ceil(el.getBoundingClientRect().width)); }
        function overflows(el) { return width(el) > avail + 1; }
        function scaleToFit(el) {
          var w = width(el);
          if (w <= avail + 1) return;
          var s = avail / w, h = el.getBoundingClientRect().height;
          var mb = parseFloat(getComputedStyle(el).marginBottom) || 0;
          if (el.dataset.fitMb === undefined) el.dataset.fitMb = el.style.marginBottom || '';
          el.style.transformOrigin = 'top left';
          el.style.transform = 'scale(' + s + ')';
          el.style.marginBottom = (mb - h * (1 - s)) + 'px';
          el.setAttribute('data-fit', '1');
          if (s < minScale) minScale = s;
        }
        function walk(el) {
          if (!overflows(el)) return;
          if (!el.matches(FIT_ATOMIC)) {
            var wide = [];
            for (var i = 0; i < el.children.length; i++) {
              if (overflows(el.children[i])) wide.push(el.children[i]);
            }
            if (wide.length) {
              for (var j = 0; j < wide.length; j++) walk(wide[j]);
              return;
            }
            el.dataset.fitMw = el.style.maxWidth || '';
            el.style.maxWidth = '100%';
            el.setAttribute('data-fit', '1');
          }
          scaleToFit(el);
        }
        for (var k = 0; k < root.children.length; k++) walk(root.children[k]);
        return minScale;
      };
    """
}
