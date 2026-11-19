package com.inbox2.app.ui.components

import android.annotation.SuppressLint
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.inbox2.app.cloud.ImageProxy
import com.inbox2.app.theme.theme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONArray

/**
 * Self-sizing email-body WebView (iOS MessageBodyWebView). Renders one message through
 * the shared `@inbox2/email-body` bundle (assets/email-body.js) — same quote/signature
 * collapse + remote-image block as the desktop iframe and iOS. The host page's bridge
 * is the only platform difference: iOS uses `webkit.messageHandlers`, Android an
 * `addJavascriptInterface` object (`AndroidBridge`). Reports content height back so
 * several stack inside one outer scroll; internal scrolling is disabled.
 *
 * Three image policies (mirror iOS):
 *  - default: remote images blocked (CSP `data: blob:`, bundle stamps `data-blocked-*`).
 *  - showRemoteImages: load DIRECTLY (CSP relaxed to https) — leaks the reader's IP,
 *    the fallback when no proxy bearer is available.
 *  - proxyImages: load PRIVATELY via the Rails proxy — the bundle still blocks every
 *    remote ref, the blocked URLs are posted to native, fetched through `ImageProxy`
 *    (bearer stays native), and swapped back in as `data:` URIs. The sender sees nothing.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun MessageBodyWebView(
    html: String,
    showRemoteImages: Boolean = false,
    proxyImages: Boolean = false,
    bearer: String? = null,
    onBlockedCount: (Int) -> Unit = {},
    directFallback: Boolean = false,
    onProxyFailed: (Int) -> Unit = {},
    /** Fires once the body first reports a height (its JS ran, so it's rendered), so
     *  the card can drop its loading spinner. There's no WebViewClient here; the
     *  height bridge is the only "rendered" signal. */
    onLoaded: () -> Unit = {},
    /** A tapped http(s) link — the reader opens the in-app browser. mailto/tel/sms go
     *  straight to the system (iOS decidePolicyFor). */
    onOpenUrl: (String) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val p = theme
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var heightPx by remember { mutableIntStateOf(80) }
    var loadedReported by remember { mutableStateOf(false) }
    val latestOnLoaded by androidx.compose.runtime.rememberUpdatedState(onLoaded)
    val bridge = remember {
        ProxyBridge(scope, onBlockedCount, onProxyFailed) { h ->
            heightPx = maxOf(24, h)
            if (!loadedReported) { loadedReported = true; latestOnLoaded() }
        }
    }
    // Build the document once per INPUT change, not per recomposition: document() mints
    // a fresh CSP nonce every call, so rebuilding it inside `update` made the reload
    // guard below never match — every height-report recomposition fully reloaded the
    // body, re-firing the image-proxy loop and wiping the bridge's failure state.
    // The theme web colors are keys too, so a theme flip still rebuilds the document.
    val doc = remember(html, showRemoteImages, proxyImages, p.webText, p.webMuted, p.webLink, p.webQuoteBorder) {
        document(html, p.webText, p.webMuted, p.webLink, p.webQuoteBorder, showRemoteImages, proxyImages, ctx)
    }

    AndroidView(
        // The bridge reports CSS-px content height; a WebView maps CSS px ~1:1 to dp, so
        // use it directly (dividing by display density clipped the body to ~1/density tall).
        modifier = modifier.fillMaxWidth().height(heightPx.dp),
        factory = {
            WebView(ctx).apply {
                settings.javaScriptEnabled = true
                // Lock the email WebView down: no file/content access, no cross-origin from
                // file URLs, no auto-opened windows, never load mixed (http) content. The
                // body loads via loadDataWithBaseURL(null,…) (opaque origin) so email JS
                // can't reach the filesystem or other origins (WKWebView-sandbox parity).
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.allowFileAccessFromFileURLs = false
                settings.allowUniversalAccessFromFileURLs = false
                settings.javaScriptCanOpenWindowsAutomatically = false
                settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
                setBackgroundColor(android.graphics.Color.TRANSPARENT)
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                // Pinch-zoom (no +/- controls); a zoomed body pans sideways with one finger.
                // The card stays exactly as tall as the zoomed content (onScaleChanged), so
                // there's never vertical overflow here and vertical drags reach the thread.
                settings.setSupportZoom(true)
                settings.builtInZoomControls = true
                settings.displayZoomControls = false
                bridge.web = this
                addJavascriptInterface(bridge, "AndroidBridge")
                webViewClient = object : android.webkit.WebViewClient() {
                    // Zoom grows the card in the thread instead of scrolling the body inside
                    // a fixed window (iOS: frame = baseHeight × zoomScale).
                    override fun onScaleChanged(view: WebView, oldScale: Float, newScale: Float) {
                        if (bridge.baseScale == 0f) bridge.baseScale = oldScale.takeIf { it > 0f } ?: newScale
                        bridge.zoom = newScale / bridge.baseScale
                        bridge.repostHeight()
                    }

                    // The body is injected (loadDataWithBaseURL) and never navigates itself —
                    // the bundle JS only mutates the DOM — so any navigation is a user tapping
                    // a link: http(s) → the in-app browser, other schemes → the system.
                    override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest): Boolean {
                        val url = request.url ?: return false
                        when (url.scheme?.lowercase()) {
                            "http", "https" -> onOpenUrl(url.toString())
                            "mailto", "tel", "sms" -> runCatching { view.context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, url)) }
                            else -> return false
                        }
                        return true
                    }

                    // The injected body finished loading — re-open any quotes the user had
                    // expanded before this (re)load (iOS didFinish → __setQuoteState).
                    override fun onPageFinished(view: WebView, url: String?) {
                        @Suppress("DEPRECATION") if (bridge.baseScale == 0f && view.scale > 0f) bridge.baseScale = view.scale
                        bridge.restoreQuoteState()
                    }

                    // The renderer was killed (usually while backgrounded), taking the DOM
                    // with it. Reload the last document so returning to the app shows the body
                    // again; onPageFinished re-applies the persisted quote state (iOS
                    // webViewWebContentProcessDidTerminate). Returning true keeps the app alive
                    // instead of the whole process crashing with the dead renderer.
                    override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
                        view.tag = null
                        bridge.lastDoc?.let { view.loadDataWithBaseURL(null, it, "text/html", "utf-8", null) }
                        return true
                    }
                }
            }
        },
        update = { web ->
            // The bearer can change after first composition (e.g. the user taps "Load
            // privately" and proxyMode flips on) — keep the bridge's copy current.
            bridge.bearer = bearer
            // A genuinely new message clears the expanded-quote memory; a theme reload (same
            // html, new colors) keeps it so the user's expansions survive the reload.
            if (bridge.lastHtml != html) { bridge.openQuotes.clear(); bridge.lastHtml = html }
            bridge.lastDoc = doc
            // Reload only when the document really changed (update fires on every
            // recomposition; reloading each time would re-proxy every image and drop
            // the collected proxy-failure state).
            val key = doc.hashCode()
            if (web.tag != key) {
                web.tag = key
                bridge.reset()
                web.loadDataWithBaseURL(null, doc, "text/html", "utf-8", null)
            }
            // Consent arrived after the failures were collected — drain them directly.
            if (directFallback) bridge.runDirectFallback()
        },
    )
}

/** JS↔native bridge: sizing/blocked callbacks + the proxy fetch-and-swap loop. */
private class ProxyBridge(
    private val scope: CoroutineScope,
    private val onBlocked: (Int) -> Unit,
    private val onProxyFailed: (Int) -> Unit,
    private val onHeight: (Int) -> Unit,
) {
    lateinit var web: WebView
    var bearer: String? = null
    /** Explicit per-message consent to fetch proxy-refused images directly. */
    @Volatile var directFallback = false
    /** Proxy jobs the upstream host refused — kept for the consented direct pass.
     *  Mutated on the main thread only (the scope is the composition's Main scope). */
    private val failedJobs = mutableListOf<Triple<String, String, String>>()

    /** Indices of quote/signature blocks the user expanded. Their open state lives in the
     *  WebView DOM (`<details open>`), which is lost on every reload (theme flip, or the
     *  renderer being jettisoned while backgrounded). Mirroring it here (per message) lets
     *  onPageFinished re-open them (iOS Coordinator.openQuotes). Main-thread only. */
    val openQuotes = mutableSetOf<Int>()
    /** The message currently rendered — a genuinely new body clears openQuotes; a theme
     *  reload keeps them. And the last document, replayed on renderer death. */
    @Volatile var lastHtml: String? = null
    var lastDoc: String? = null

    /** The WebView's own initial scale (density-driven) — zoom is measured against it. */
    var baseScale = 0f
    /** Current pinch zoom relative to the initial scale; the card height is base × this. */
    var zoom = 1f
    private var baseHeight = 0
    @JavascriptInterface fun sizing(h: Int) = web.post { baseHeight = h; onHeight((h * zoom).toInt()) }
    fun repostHeight() { if (baseScale == 0f) return; if (baseHeight > 0) onHeight((baseHeight * zoom).toInt()) }
    @JavascriptInterface fun blocked(n: Int) = web.post { onBlocked(n) }
    @JavascriptInterface fun quoteState(index: Int, open: Boolean) =
        web.post { if (open) openQuotes.add(index) else openQuotes.remove(index) }

    /** Re-open the blocks the user had expanded before this (re)load (iOS didFinish). Empty
     *  on a first load → no-op; on a reload it re-applies over the freshly built defaults. */
    fun restoreQuoteState() {
        if (openQuotes.isEmpty()) return
        val arr = openQuotes.sorted().joinToString(",")
        web.evaluateJavascript("window.__setQuoteState && window.__setQuoteState([$arr])", null)
    }

    /** The page collected the blocked image URLs (`[{id,kind,url}]`); fetch each
     *  through the Rails proxy and swap the returned data: URI back in. Hosts that
     *  refuse the proxy (bot-managed CDNs 403 server-side clients) are stashed for
     *  the graceful-degradation "Load directly" banner — or fetched directly right
     *  away when consent was already given. */
    @JavascriptInterface fun proxy(jobsJson: String) {
        val jobs = runCatching { JSONArray(jobsJson) }.getOrNull() ?: return
        // Defence in depth: the CSP nonce already keeps email JS from reaching this
        // bridge, but the bearer rides along with every fetch, so never proxy a URL
        // the page named that the email itself doesn't contain.
        val allow = ProxyAllowlist(lastHtml ?: "")
        for (i in 0 until jobs.length()) {
            val job = jobs.optJSONObject(i) ?: continue
            val id = job.optString("id"); val kind = job.optString("kind"); val url = job.optString("url")
            if (id.isEmpty() || url.isEmpty()) continue
            if (!allow.permits(url)) { android.util.Log.w("com.inbox2.reader", "proxy: refused URL not present in the email body"); continue }
            scope.launch {
                var dataUri = ImageProxy.fetchDataURI(url, bearer)
                if (dataUri == null) {
                    if (directFallback) {
                        dataUri = ImageProxy.fetchDirectDataURI(url)
                    } else {
                        failedJobs += Triple(id, kind, url)
                        onProxyFailed(failedJobs.size)
                    }
                }
                apply(id, kind, dataUri ?: return@launch)
            }
        }
    }

    /** Drain the proxy-refused jobs via consented direct fetches (data: URIs, so the
     *  strict CSP holds). Idempotent — the list empties as it drains. */
    fun runDirectFallback() {
        directFallback = true
        val jobs = failedJobs.toList()
        failedJobs.clear()
        for ((id, kind, url) in jobs) scope.launch {
            apply(id, kind, ImageProxy.fetchDirectDataURI(url) ?: return@launch)
        }
    }

    /** New document — forget the previous one's failures. */
    fun reset() {
        directFallback = false
        if (failedJobs.isNotEmpty()) { failedJobs.clear(); onProxyFailed(0) }
    }

    private fun apply(id: String, kind: String, dataUri: String) {
        val js = "window.__applyProxied(${jsLiteral(id)},${jsLiteral(kind)},${jsLiteral(dataUri)})"
        web.post { web.evaluateJavascript(js, null) }
    }
}

/**
 * The remote URLs native may fetch for a message: exactly those the email HTML carries.
 * The bundle lifts them from attributes (so the DOM has entities decoded — `&amp;` →
 * `&`) or from `url(...)` in inline styles; both are substrings of the raw or the
 * entity-decoded source, so containment is the whole check (no URL grammar to get
 * wrong). Pure, so it can be unit-tested without a WebView.
 */
internal class ProxyAllowlist(private val html: String) {
    private val decoded by lazy { htmlUnescape(html) }
    fun permits(url: String): Boolean {
        val u = url.trim()
        if (u.isEmpty()) return false
        val scheme = u.substringBefore(':', "").lowercase()
        if (scheme != "http" && scheme != "https" && !u.startsWith("//")) return false
        return html.contains(u) || decoded.contains(u)
    }

    companion object {
        private val entity = Regex("&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);")
        fun htmlUnescape(s: String): String = entity.replace(s) { m ->
            when (val e = m.groupValues[1]) {
                "amp" -> "&"; "quot" -> "\""; "apos" -> "'"; "lt" -> "<"; "gt" -> ">"; "nbsp" -> "\u00a0"
                else -> runCatching {
                    val cp = if (e.startsWith("#x")) e.substring(2).toInt(16) else e.substring(1).toInt()
                    String(Character.toChars(cp))
                }.getOrDefault(m.value)
            }
        }
    }
}

private fun jsLiteral(s: String): String = JSONArray().put(s).toString().let { it.substring(1, it.length - 1) }

private fun document(
    body: String, webText: String, webMuted: String, webLink: String, webQuoteBorder: String,
    showImages: Boolean, proxy: Boolean, ctx: android.content.Context,
): String {
    val bundle = runCatching { ctx.assets.open("email-body.js").bufferedReader().use { it.readText() } }.getOrDefault("")
    val bodyJson = JSONArray().put(body).toString()
    // Per-document CSP nonce. The body is untrusted provider HTML and JS must stay on
    // (the bundle driver + the AndroidBridge need it), so instead we lock script
    // execution to OUR two nonce-tagged <script> tags via `script-src 'nonce-…'` (no
    // 'unsafe-inline'). That blocks the email's own inline <script>, `on*=` handlers and
    // `javascript:` URLs from running — so email content can't reach AndroidBridge.
    // This is the Android equivalent of the iOS "disable content JavaScript" fix.
    val nonce = run {
        val bytes = ByteArray(16); java.security.SecureRandom().nextBytes(bytes)
        android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING)
    }
    // Direct mode (no proxy bearer, user tapped "Show images") relaxes the CSP to https.
    // Proxy mode keeps it strict — images arrive as data: URIs from native.
    val direct = showImages && !proxy
    val imgSrc = if (direct) "data: blob: https:" else "data: blob:"
    val block = if (direct) "false" else "true"
    // In proxy mode the bundle still blocks every remote ref (stashed on data-*), then
    // this collects them for native to fetch + swap back in (iOS proxyJS port).
    val proxyJs = if (proxy) """
          window.__applyProxied = function (id, kind, dataUri) {
            var el = document.querySelector('[data-proxy-id="' + id + '"]');
            if (!el) return;
            if (kind === 'bg') { el.style.backgroundImage = 'url("' + dataUri + '")'; }
            else { el.setAttribute('src', dataUri); }
            window.relayout();
          };
          (function () {
            var els = root.querySelectorAll('[data-blocked-src],[data-blocked-bg],[data-blocked-srcset]');
            var jobs = [];
            els.forEach(function (el, i) {
              var id = 'p' + i;
              el.setAttribute('data-proxy-id', id);
              if (el.dataset.blockedSrcset) { el.removeAttribute('srcset'); }
              if (el.dataset.blockedSrc) jobs.push({ id: id, kind: 'src', url: el.dataset.blockedSrc });
              if (el.dataset.blockedBg) jobs.push({ id: id, kind: 'bg', url: el.dataset.blockedBg });
            });
            if (jobs.length) { try { AndroidBridge.proxy(JSON.stringify(jobs)); } catch (e) {} }
          })();
    """ else ""
    return """
        <!doctype html><html dir="auto"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src $imgSrc; style-src 'unsafe-inline'; font-src data:; script-src 'nonce-$nonce';">
        <style>${EmailReaderCss.CSS}</style></head>
        <body><div id="body"></div>
        <script nonce="$nonce">$bundle</script>
        <script nonce="$nonce">
          (function () {
            function postHeight() {
              // __fitEmail scales elements in place and compensates the leftover layout
              // height, so the document height is the true rendered height.
              try { AndroidBridge.sizing(document.documentElement.scrollHeight); } catch (e) {}
            }
            window.postHeight = postHeight;
            // Keep white only when the email relies on it; if the email paints its own
            // background (sampled at a few points), go transparent so the app surface
            // shows through and self-styled emails aren't framed in white. Mirrors the
            // desktop iframe's applyBackground.
            function applyBackground() {
              var docEl = document.documentElement, b = document.body;
              if (!b) return;
              var w = docEl.clientWidth, h = docEl.clientHeight;
              function sample(x, y) {
                var el = document.elementFromPoint(Math.round(x), Math.round(Math.min(y, h - 1)));
                while (el && el !== b && el !== docEl) {
                  var cs = getComputedStyle(el);
                  var opaque = cs.backgroundColor && !/^(transparent|rgba\(0,\s*0,\s*0,\s*0\))$/.test(cs.backgroundColor);
                  if (opaque || cs.backgroundImage !== 'none') return true;
                  el = el.parentElement;
                }
                return false;
              }
              var pts = [[w * 0.5, 24], [w * 0.25, h * 0.5], [w * 0.75, h * 0.5]];
              var painted = pts.filter(function (p) { return sample(p[0], p[1]); }).length;
              var transparent = painted >= 2;
              var bg = transparent ? 'transparent' : '#ffffff';
              docEl.style.background = bg;
              b.style.background = bg;
              b.style.padding = transparent ? '0px' : '';
              postHeight();
            }
            window.applyBackground = applyBackground;
            var SAMPLE = ($bodyJson)[0];
            // Height backstop (last stylesheet wins): forces height:auto so templates
            // that set html/body height:100% can't clamp the document height and
            // collapse the body to a sliver.
            (function () {
              var fit = document.createElement('style');
              fit.textContent = '${EmailReaderCss.FIT_BACKSTOP_CSS}';
              document.head.appendChild(fit);
            })();
            var r = Inbox2EmailBody.processBody(SAMPLE, { block: $block });
            var root = document.getElementById('body');
            window.root = root;
            root.innerHTML = r.html;
            ${EmailReaderCss.FIT_JS}
            // Quote/signature collapse lives in the DOM as <details open>. That state is
            // lost on reload, so each block carries a stable index: toggles are posted to
            // native, and __setQuoteState (called from onPageFinished after a reload)
            // re-opens the ones the user had expanded (iOS parity).
            window.__quoteDetails = [];
            root.querySelectorAll('[data-quoted-block],[data-signature-block]').forEach(function (el, i) {
              var details = document.createElement('details');
              var summary = document.createElement('summary');
              var isSig = el.matches('[data-signature-block]');
              summary.textContent = isSig ? 'signature ···' : 'quoted text ···';
              // Bare forward (no added note): expand the quote so the card isn't blank.
              if (!isSig && r.quotesOnly) details.open = true;
              el.parentNode.insertBefore(details, el);
              details.appendChild(summary);
              details.appendChild(el);
              window.__quoteDetails.push(details);
              details.addEventListener('toggle', function () {
                try { AndroidBridge.quoteState(i, details.open); } catch (e) {}
                window.relayout();
              });
            });
            window.__setQuoteState = function (indices) {
              if (!window.__quoteDetails) return;
              indices.forEach(function (i) {
                var d = window.__quoteDetails[i];
                if (d && !d.open) d.open = true;
              });
              window.relayout();
            };
            $proxyJs
            try { AndroidBridge.blocked(r.blockedCount); } catch (e) {}
            // Scale-to-fit, set the canvas, then report height — at each point the layout
            // can shift (initial, image load, font, proxied images, collapse).
            function relayout() { applyBackground(); window.__fitEmail(); postHeight(); }
            window.relayout = relayout;
            if (window.ResizeObserver) { new ResizeObserver(postHeight).observe(document.body); }
            window.addEventListener('load', relayout);
            requestAnimationFrame(relayout);
            setTimeout(relayout, 600);    // re-fit once remote/proxied images paint
            setTimeout(relayout, 1200);
            relayout();
          })();
        </script>
        </body></html>
    """.trimIndent()
}
