/// The CSS + reflow JS the email reader injects around an email body before rendering
/// it in the WebView. Extracted from `MessageBodyWebView.document(...)` into pure
/// constants so the layout harness (`EmailBodyLayoutTests`) renders fixtures through the
/// EXACT same assets the app ships.
///
/// Strategy: **reflow, and scale only what refuses to reflow** — Gmail's mobile behaviour.
/// Text containers wrap into the phone column at full size; the elements whose width IS
/// their design (a table, a wide image, a `<pre>`) can't wrap without being destroyed, so
/// those alone are scaled down to fit. A 600px MJML marketing email is one such table and
/// scales as a whole, exactly as before; a business thread with prose plus one 1600px
/// quoted table keeps its prose readable and shrinks only the table.
///
/// Scaling the WHOLE body was the previous strategy and it broke on that second case: one
/// ultra-wide element deep in a quote chain took the entire email down to ~0.2 and made
/// the prose an unreadable thumbnail.
enum EmailReaderCSS {
    /// Height backstop, injected as the LAST stylesheet (after the email's own
    /// <style> blocks) so its !important rules win the cascade. Many templates
    /// (PayPal receipts, MJML) set `html,body{height:100%}`, which clamps the
    /// measured document height to the small initial WebView frame and collapses
    /// the body to a sliver — only the top (a logo) shows. Forcing height:auto lets
    /// the document size to its content. Mirrors the desktop iframe's FRAME_FIT_CSS.
    static let fitBackstopCss = "html,body{height:auto!important;min-height:0!important;}body{display:flow-root!important;}"

    static let css = """
      /* Default to a WHITE canvas with dark text (matching the desktop iframe):
         real-world HTML emails ship their own dark-text-on-light styling and assume
         a white background. The detection script drops back to transparent — letting
         the dark app surface show through — only when the email paints its own
         background, so fully-styled (incl. dark) emails still render correctly. */
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
      summary { color: #1a73e8; cursor: pointer; list-style: none; font: 14px -apple-system, system-ui; padding: 4px 0; }
      a { color: #1a73e8; }
      blockquote { border-left: 3px solid #dadce0; margin: 8px 0; padding-left: 12px; }
    """

    /// Defines `window.__fitEmail()` — the per-element fit pass. Run after the body is
    /// inserted and again as images settle / a quote expands. Idempotent: each run first
    /// undoes the previous one, so it always measures a clean layout.
    ///
    /// It walks down from `#body` into whatever overflows the column, and at each node
    /// takes the first option that works:
    ///
    /// 1. **Fits already** — leave it alone. Ordinary prose is already wrapping at the
    ///    column width, so it is never touched and never shrinks. (This is why we measure
    ///    at the real column width and never at `max-content`: with max-content every
    ///    paragraph lays out on one non-wrapping line and reports a bogus width of
    ///    thousands of px.)
    /// 2. **Something inside it is the wide one** — recurse, so we end up at the wide
    ///    table itself rather than the wrapper holding it *and* three pages of prose.
    /// 3. **Its own box is too wide** — reflow it (`max-width:100%`), the way Gmail wraps
    ///    a fixed-width container of text into the column.
    /// 4. **Still too wide after reflowing, or it can't reflow at all** (a table, image,
    ///    `<pre>` — width IS the design) — scale that element alone with a transform.
    ///
    /// A transform shrinks paint, not layout, so a scaled element keeps its wide layout
    /// box (`#body{overflow-x:hidden}` clips it) and its full layout height (a negative
    /// margin-bottom pulls the difference back, so the document height — and therefore
    /// the height the WebView reports — matches what is on screen).
    ///
    /// Returns the smallest scale applied (1 = nothing was scaled), which the layout
    /// harness asserts on.
    static let fitJS = """
      // Elements whose width is their design: reflowing them destroys the layout, so
      // these are scaled whole and never descended into.
      var FIT_ATOMIC = 'table,img,pre,svg,video,canvas,iframe,object,figure';
      window.__fitEmail = function () {
        var root = document.getElementById('body');
        if (!root) return 1;
        var avail = root.clientWidth;                      // column width (respects body padding)
        if (!avail) return 1;                              // not laid out yet — a later run will fit it
        // Undo the previous pass so this one measures the email's own layout.
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
          if (!overflows(el)) return;                                  // 1. fits — done
          if (!el.matches(FIT_ATOMIC)) {
            var wide = [];
            for (var i = 0; i < el.children.length; i++) {
              if (overflows(el.children[i])) wide.push(el.children[i]);
            }
            if (wide.length) {                                         // 2. blame the children
              for (var j = 0; j < wide.length; j++) walk(wide[j]);
              return;
            }
            el.dataset.fitMw = el.style.maxWidth || '';                // 3. reflow this box
            el.style.maxWidth = '100%';
            el.setAttribute('data-fit', '1');
          }
          scaleToFit(el);                                              // 4. last resort
        }
        for (var k = 0; k < root.children.length; k++) walk(root.children[k]);
        return minScale;
      };
    """
}
