import SwiftUI
import WebKit
import UIKit

/// A self-sizing email-body web view for threaded reading: it renders one message
/// through the shared `@inbox2/email-body` bundle (same quote/signature collapse +
/// remote-image block as the desktop iframe and the single-message `ReaderView`),
/// then reports its content height back so several can stack inside one outer
/// SwiftUI `ScrollView`. Internal scrolling is disabled — the thread scrolls as a
/// whole. Body metadata is logged (not shown) so the cards stay clean.
struct MessageBodyWebView: UIViewRepresentable {
    @Environment(\.theme) private var theme
    let html: String
    @Binding var height: CGFloat
    /// When true, remote images are loaded DIRECTLY (the user pressed "Show images"
    /// with no proxy bearer available); the CSP is relaxed to allow https and the
    /// shared JS skips remote-content blocking. This leaks the reader's IP, so it's
    /// the fallback path only. Inline images (data URIs) always render.
    var showRemoteImages: Bool = false
    /// When true, remote images are loaded PRIVATELY through the Rails proxy: the
    /// shared JS still blocks every remote ref (CSP stays `data: blob:`), then posts
    /// the blocked URLs to native, which fetches each via `ImageProxy` and swaps the
    /// returned `data:` URI back in. The sender never sees the device.
    var proxyImages: Bool = false
    /// The personal API key the proxy authenticates with (nil falls back to the MX
    /// session token inside `ImageProxy`). Only consulted in `proxyImages` mode.
    var apiKey: String? = nil
    /// Reports how many remote resources were blocked, so the card can offer a
    /// "Show images" control.
    var onBlockedCount: ((Int) -> Void)? = nil
    /// When true (an explicit "Load directly" tap), the images the proxy could NOT
    /// fetch — bot-managed CDNs 403 server-side clients — are fetched directly from
    /// the device and swapped in as `data:` URIs. The CSP stays strict; the reader's
    /// IP is revealed only to the hosts that refused the proxy, only after consent.
    var directFallback: Bool = false
    /// Reports how many proxied image fetches the upstream host refused, so the card
    /// can offer the graceful-degradation "Load directly" banner.
    var onProxyFailed: ((Int) -> Void)? = nil
    /// Fires once the injected body document finishes loading (the bundle JS has run
    /// and the DOM is rendered), so the card can drop its "rendering" spinner. Without
    /// this the body area sits blank between mount and the first height post.
    var onLoaded: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// One pool shared by every message body in the app. A fresh `WKWebViewConfiguration`
    /// gets a fresh `WKProcessPool`, and each pool means its own WebKit content process
    /// (~40–80 MB) — so a thread with several expanded messages spawned several. Those
    /// processes are charged to our jetsam footprint. Sharing the pool lets WebKit reuse
    /// one content process across the cards. Security is unchanged: page JS stays off and
    /// the CSP is per-page.
    private static let sharedPool = WKProcessPool()

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = Self.sharedPool
        // The body is untrusted provider HTML, so the email's OWN JavaScript is
        // disabled: this kills inline `<script>`, `on*=` event handlers, and
        // `javascript:` URLs — the classic email-client XSS vectors — and matches
        // Gmail/Apple Mail. Our rendering driver is injected as a `WKUserScript`
        // (in `render`), which is unaffected by this flag, as is native
        // `evaluateJavaScript`. The page therefore also can't forge our `sizing`/
        // `proxy`/`quote` message-handler posts.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "sizing")
        ucc.add(context.coordinator, name: "log")
        ucc.add(context.coordinator, name: "blocked")
        ucc.add(context.coordinator, name: "proxy")
        ucc.add(context.coordinator, name: "quote")
        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false   // outer ScrollView owns scrolling
        // Pinch-zoom re-enables it (see `scrollViewDidZoom`) so the zoomed body can be
        // panned sideways with one finger. Bouncing off, insets off: the card's frame is
        // kept exactly as tall as the zoomed content, so there is never vertical overflow
        // here and UIScrollView hands vertical drags up to the thread scroll view.
        webView.scrollView.delegate = context.coordinator
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Render emails in their LIGHT design on our white canvas, regardless of the
        // device theme. WKWebView otherwise reports the system dark mode to the page,
        // so an email's `@media (prefers-color-scheme: dark)` rules paint its sections
        // dark — which then trips the self-painted-background detection into going
        // transparent + edge-to-edge (Vestiaire). Forcing light keeps it deterministic
        // and matches Gmail/Apple Mail; responsive `max-width` media queries still apply.
        webView.overrideUserInterfaceStyle = .light
        webView.navigationDelegate = context.coordinator
        context.coordinator.render(webView, html: html, palette: theme.palette, showImages: showRemoteImages, proxy: proxyImages)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Only reload when the body, theme, or image policy changed (updateUIView
        // fires on every layout pass; reloading each time would loop with height).
        context.coordinator.render(webView, html: html, palette: theme.palette, showImages: showRemoteImages, proxy: proxyImages)
        // Consent arrived after the failures were collected — drain them directly.
        if directFallback { context.coordinator.runDirectFallback(webView) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate {
        var parent: MessageBodyWebView
        private var lastKey: String = ""
        /// The page-reported document height at zoom 1. The card's frame is this times
        /// the current pinch-zoom scale, so zooming grows the card in the thread instead
        /// of scrolling the body inside a fixed window. Main-thread only.
        private var baseHeight: CGFloat = 24
        /// Proxy jobs the upstream host refused — kept for the consented direct pass.
        /// Main-thread only (script messages and Tasks both land on main).
        private var failedJobs: [(id: String, kind: String, url: String)] = []
        /// Indices of quote/signature blocks the user expanded. The expand state lives
        /// in the WKWebView DOM (`<details open>`), which is lost whenever the page
        /// reloads — most notably after iOS jettisons the web-content process while the
        /// app is backgrounded. Mirroring it here (per-message; one Coordinator per
        /// card) lets `didFinish` restore it on every reload. Main-thread only.
        private var openQuotes: Set<Int> = []
        init(_ parent: MessageBodyWebView) { self.parent = parent }

        /// The body is injected via `loadHTMLString` (baseURL nil → about:blank) and
        /// never navigates itself — the bundle JS only mutates the DOM. So any real
        /// navigation is a user tapping a link: hand http(s) and mailto/tel/sms to the
        /// system (the default browser or app), allow the rest (the initial about:blank
        /// document load).
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isUserNav = navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil
            guard isUserNav, let url = navigationAction.request.url else { decisionHandler(.allow); return }
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto", "tel", "sms", "facetime":
                decisionHandler(.cancel)
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            default:
                decisionHandler(.allow)
            }
        }

        /// The injected body document finished loading — the bundle JS has run, so the
        /// card can drop its rendering spinner. (Link taps are cancelled in
        /// `decidePolicyFor`, so this only fires for the `loadHTMLString` document.)
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Restore any quotes the user had expanded before this (re)load. Empty on a
            // first load (no-op); on a reload — theme change or, crucially, the silent
            // reload after a backgrounded web-content process is jettisoned — this
            // re-opens the blocks so returning to the app doesn't snap them collapsed.
            if !openQuotes.isEmpty {
                let arr = openQuotes.sorted().map(String.init).joined(separator: ",")
                webView.evaluateJavaScript("window.__setQuoteState && window.__setQuoteState([\(arr)])", completionHandler: nil)
            }
            DispatchQueue.main.async { [weak self] in self?.parent.onLoaded?() }
        }

        /// The web-content process was jettisoned (commonly while backgrounded), taking
        /// the rendered DOM with it. WebKit shows a blank/snapshot frame until reloaded,
        /// so force a fresh render; `didFinish` then re-applies the persisted quote state.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            lastKey = ""
            render(webView, html: parent.html, palette: parent.theme.palette,
                   showImages: parent.showRemoteImages, proxy: parent.proxyImages)
        }

        func render(_ webView: WKWebView, html: String, palette: ThemePalette, showImages: Bool, proxy: Bool) {
            // `updateUIView` fires on every layout pass; this guard runs each time. Key
            // off `utf8.count` (O(1) for native strings) rather than `html.hashValue`,
            // which rehashes the whole body every pass — brutal for image-heavy mail
            // whose body is multi-MB of base64 data: URIs. Within one card the body only
            // changes on enrich (stored→full), which changes the length, so count is a
            // sufficient change signal alongside the theme (keyed on its reader bg, so
            // Light ↔ Atelier re-renders too) and image flags.
            let key = "\(palette.webBg)|\(showImages ? "i" : "b")|\(proxy ? "p" : "-")|\(html.utf8.count)"
            guard key != lastKey else { return }
            lastKey = key
            if !failedJobs.isEmpty {
                failedJobs = []
                DispatchQueue.main.async { [weak self] in self?.parent.onProxyFailed?(0) }
            }
            let direct = showImages && !proxy
            let imgSrc = direct ? "data: blob: https:" : "data: blob:"
            // Page JS is disabled (see makeUIView), so the driver runs as an injected
            // user script instead of an inline `<script>`. Rebuilt each render so it
            // carries the current body + image policy; user scripts apply to every
            // subsequent load, so clear before re-adding.
            let ucc = webView.configuration.userContentController
            ucc.removeAllUserScripts()
            ucc.addUserScript(WKUserScript(
                source: MessageBodyWebView.driverJS(for: html, palette: palette, showImages: showImages, proxy: proxy),
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            // A reload drops back to 1×, and no zoom callback fires — re-lock scrolling.
            webView.scrollView.isScrollEnabled = false
            webView.loadHTMLString(MessageBodyWebView.pageHTML(imgSrc: imgSrc), baseURL: nil)
        }

        /// Drain the proxy-refused jobs via consented direct fetches (data: URIs, so
        /// the strict CSP holds). Idempotent — the list empties as it drains.
        func runDirectFallback(_ webView: WKWebView) {
            guard !failedJobs.isEmpty else { return }
            let jobs = failedJobs
            failedJobs = []
            for job in jobs {
                Task { @MainActor in
                    guard let dataURI = await ImageProxy.fetchDirectDataURI(job.url) else { return }
                    let js = "window.__applyProxied(\(Self.jsLiteral(job.id)),\(Self.jsLiteral(job.kind)),\(Self.jsLiteral(dataURI)))"
                    webView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        }

        /// Pinch-zoom changed the scale. Panning is only possible while the scroll view
        /// is enabled, so turn it on above 1× — that's what makes one-finger left/right
        /// work on a zoomed body (before, only the two-finger pinch recogniser panned).
        /// The frame grows with the zoom so the content still fits vertically: the pan
        /// then can't scroll up/down here, and UIScrollView forwards vertical drags to
        /// the thread scroll view exactly as before.
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let zoomed = scrollView.zoomScale > 1.001
            scrollView.isScrollEnabled = zoomed
            if !zoomed { scrollView.contentOffset.x = 0 }
            applyHeight(zoom: scrollView.zoomScale)
        }

        /// Push `baseHeight × zoom` into the card's height binding (main thread only).
        private func applyHeight(zoom: CGFloat) {
            // A hair of slack while zoomed: rounding could otherwise leave the content a
            // fraction taller than the frame, which would let the inner scroll view claim
            // vertical drags away from the thread.
            let h = zoom > 1.001 ? (baseHeight * zoom).rounded(.up) + 1 : baseHeight
            if abs(parent.height - h) > 0.5 { parent.height = h }
        }

        /// Encode a Swift string as a JS string literal (quotes + escaping) so it can
        /// be spliced into an `evaluateJavaScript` call safely.
        private static func jsLiteral(_ s: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [s]),
                  let arr = String(data: data, encoding: .utf8) else { return "''" }
            return String(arr.dropFirst().dropLast())   // strip the wrapping [ ]
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "sizing":
                if let h = message.body as? Double {
                    let zoom = message.webView?.scrollView.zoomScale ?? 1
                    DispatchQueue.main.async { [weak self] in
                        self?.baseHeight = CGFloat(max(24, h))
                        self?.applyHeight(zoom: zoom)
                    }
                }
            case "blocked":
                if let n = message.body as? Double {
                    DispatchQueue.main.async { [weak self] in self?.parent.onBlockedCount?(Int(n)) }
                }
            case "proxy":
                // The page collected the blocked image URLs; fetch each through the
                // Rails proxy and swap the returned data: URI back in. Token stays
                // native — it's never exposed to the WebView.
                guard let jobs = message.body as? [[String: Any]], let webView = message.webView else { break }
                let apiKey = parent.apiKey
                for job in jobs {
                    guard let id = job["id"] as? String,
                          let kind = job["kind"] as? String,
                          let urlStr = job["url"] as? String else { continue }
                    Task { @MainActor in
                        var dataURI = await ImageProxy.fetchDataURI(urlStr, apiKey: apiKey)
                        if dataURI == nil {
                            // Upstream refused the proxy. With consent already given,
                            // fall through to a direct fetch now; otherwise stash the
                            // job and surface the "couldn't load privately" banner.
                            if self.parent.directFallback {
                                dataURI = await ImageProxy.fetchDirectDataURI(urlStr)
                            } else {
                                self.failedJobs.append((id: id, kind: kind, url: urlStr))
                                self.parent.onProxyFailed?(self.failedJobs.count)
                            }
                        }
                        guard let dataURI else { return }
                        let js = "window.__applyProxied(\(Self.jsLiteral(id)),\(Self.jsLiteral(kind)),\(Self.jsLiteral(dataURI)))"
                        webView.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
            case "quote":
                // A quote/signature block was expanded or collapsed — remember it so the
                // state survives a reload (background jettison, theme change).
                if let dict = message.body as? [String: Any], let index = dict["index"] as? Double {
                    if (dict["open"] as? Bool) == true { openQuotes.insert(Int(index)) }
                    else { openQuotes.remove(Int(index)) }
                }
            case "log":
                Log.reader.info("body: \(String(describing: message.body))")
            default: break
            }
        }
    }

    /// The page shell — head (CSP + styles) + an empty body. Carries NO `<script>`:
    /// the email's own JavaScript is disabled and our driver is injected separately
    /// as a `WKUserScript`, so untrusted body markup can't run script. `default-src
    /// 'none'` blocks every remote fetch (scripts, fonts, frames, XHR); `img-src`
    /// allows the inlined `data:`/`blob:` images (plus `https:` in consented direct
    /// mode); `style-src 'unsafe-inline'` keeps the email's own inline styles working.
    private static func pageHTML(imgSrc: String) -> String {
        return """
        <!doctype html><html dir="auto"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imgSrc); style-src 'unsafe-inline'; font-src data:;">
        <style>\(EmailReaderCSS.css)</style></head>
        <body><div id="body"></div></body></html>
        """
    }

    /// The rendering driver, injected as a `WKUserScript` at document end. Same logic
    /// as the old inline `<script>` pair (bundle + processBody + quote/sizing/proxy
    /// wiring) — moved out of the page so it runs even with page JS disabled. Built
    /// per render so it carries the current body + image policy.
    private static func driverJS(for body: String, palette: ThemePalette, showImages: Bool, proxy: Bool) -> String {
        let bundleJS: String = {
            guard let url = Bundle.main.url(forResource: "email-body", withExtension: "js"),
                  let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return js
        }()
        let bodyJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: [body]),
                  let s = String(data: data, encoding: .utf8) else { return "[\"\"]" }
            return s
        }()
        // Direct mode (no proxy bearer, user tapped "Show images") relaxes the CSP to
        // https. Proxy mode keeps it strict — images arrive as data: URIs from native,
        // so https is never needed and nothing can phone home.
        let direct = showImages && !proxy
        // In proxy mode the bundle still blocks every remote ref (stashed on data-*),
        // then this collects them for native to fetch + swap back in.
        let proxyJS = proxy ? """
          window.__applyProxied = function (id, kind, dataUri) {
            var el = document.querySelector('[data-proxy-id="' + id + '"]');
            if (!el) return;
            if (kind === 'bg') { el.style.backgroundImage = 'url("' + dataUri + '")'; }
            else { el.setAttribute('src', dataUri); }
            relayout();
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
            if (jobs.length) { try { webkit.messageHandlers.proxy.postMessage(jobs); } catch (e) {} }
          })();
        """ : ""
        return """
        \(bundleJS)
        ;(function () {
            var root = document.getElementById('body');
            function postHeight() {
              // __fitEmail scales elements in place and compensates the leftover layout
              // height, so the document height is the true rendered height.
              try { webkit.messageHandlers.sizing.postMessage(document.documentElement.scrollHeight); } catch (e) {}
            }
            // The white canvas is the default and stays for the vast majority of
            // (light) emails. Only drop it — going transparent + edge-to-edge so the
            // dark app surface shows through — when a SINGLE non-white background (or
            // background image) covers most of the email: a true full-bleed design that
            // the white frame would look wrong around. A few colored blocks on an
            // otherwise white email (e.g. Vestiaire) keep the canvas + padding.
            function applyBackground() {
              var docEl = document.documentElement, b = document.body;
              if (!b) return;
              var w = docEl.clientWidth;
              // Sample only the email's own content region (the webview is sized to it),
              // never empty viewport space below it.
              var H = Math.min(docEl.clientHeight, Math.max(1, Math.round(root.getBoundingClientRect().height)));
              function nearWhite(c) { var m = c.match(/(\\d+),\\s*(\\d+),\\s*(\\d+)/); return m ? (+m[1] >= 236 && +m[2] >= 236 && +m[3] >= 236) : false; }
              function bgAt(x, y) {
                var el = document.elementFromPoint(Math.round(x), Math.round(Math.min(y, H - 1)));
                while (el && el !== b && el !== docEl) {
                  var cs = getComputedStyle(el);
                  if (cs.backgroundImage && cs.backgroundImage !== 'none') return 'img';
                  var c = cs.backgroundColor;
                  if (c && !/^(transparent|rgba\\(0,\\s*0,\\s*0,\\s*0\\))$/.test(c)) return c;
                  el = el.parentElement;
                }
                return null;
              }
              var xs = [w * 0.12, w * 0.5, w * 0.88], counts = {}, total = 0;
              for (var i = 0; i < xs.length; i++) {
                for (var k = 1; k <= 7; k++) {
                  var c = bgAt(xs[i], H * k / 8);
                  total++;
                  if (c && !(c !== 'img' && nearWhite(c))) counts[c] = (counts[c] || 0) + 1;
                }
              }
              var domV = 0;
              for (var key in counts) { if (counts[key] > domV) domV = counts[key]; }
              var transparent = total > 0 && domV / total >= 0.5;
              var bg = transparent ? 'transparent' : '#ffffff';
              docEl.style.background = bg;
              b.style.background = bg;
              b.style.padding = transparent ? '0px' : '';
              postHeight();
            }
            var SAMPLE = (\(bodyJSON))[0];
            // Preserve the email's own <style> blocks — crucially the responsive media
            // queries that usually live in <head>. processBody returns only the parsed
            // body.innerHTML, so those head styles are dropped, which collapses a
            // responsive email (Schaap & Citroen) back into its raw fixed-width tables —
            // the squished multi-column render. Re-injecting the styles lets such emails
            // render responsively, exactly like Gmail / the desktop iframe. @import and
            // remote url() are stripped for privacy (mirrors the desktop sanitizeStyleSheets;
            // the strict CSP already blocks remote images).
            try {
              var srcDoc = new DOMParser().parseFromString(SAMPLE, 'text/html');
              srcDoc.querySelectorAll('style').forEach(function (s) {
                var css = (s.textContent || '')
                  .replace(/@import[^;]+;/gi, '')
                  .replace(/url\\(\\s*(['"]?)(https?:)?\\/\\/[^'")]+\\1\\s*\\)/gi, 'none');
                var e = document.createElement('style');
                e.textContent = css;
                document.head.appendChild(e);
              });
            } catch (e) {}
            // Height backstop — appended AFTER the email's styles so it wins: forces
            // height:auto so templates that set html/body height:100% (PayPal) can't
            // clamp the measured document height to the frame and collapse to a sliver.
            (function () {
              var fit = document.createElement('style');
              fit.textContent = '\(EmailReaderCSS.fitBackstopCss)';
              document.head.appendChild(fit);
            })();
            var r = Inbox2EmailBody.processBody(SAMPLE, { block: \(direct ? "false" : "true") });
            root.innerHTML = r.html;
            \(EmailReaderCSS.fitJS)
            // Quote/signature collapse lives in the DOM as <details open>. That state is
            // lost on reload, so each block carries a stable index: toggles are posted to
            // native, and __setQuoteState (called from didFinish after a reload) re-opens
            // the ones the user had expanded.
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
                try { webkit.messageHandlers.quote.postMessage({ index: i, open: details.open }); } catch (e) {}
                relayout();
              });
            });
            window.__setQuoteState = function (indices) {
              if (!window.__quoteDetails) return;
              indices.forEach(function (i) {
                var d = window.__quoteDetails[i];
                if (d && !d.open) d.open = true;
              });
              relayout();
            };
            \(proxyJS)
            try { webkit.messageHandlers.log.postMessage('quote=' + r.hasQuote + ' signature=' + r.hasSignature + ' blocked=' + r.blockedCount); } catch (e) {}
            try { webkit.messageHandlers.blocked.postMessage(r.blockedCount); } catch (e) {}
            // Scale-to-fit, set the white/transparent canvas, then report height — at each
            // point the layout can shift (initial, image load, font, proxied images, collapse).
            function relayout() { applyBackground(); window.__fitEmail(); postHeight(); }
            if (window.ResizeObserver) { new ResizeObserver(postHeight).observe(document.body); }
            window.addEventListener('load', relayout);
            requestAnimationFrame(relayout);
            setTimeout(relayout, 600);    // re-fit once remote/proxied images paint
            setTimeout(relayout, 1200);
            relayout();
          })();
        """
    }
}
