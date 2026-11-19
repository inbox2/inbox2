import SwiftUI
import WebKit

/// Renders an email body in a `WKWebView` through the shared `@inbox2/email-body`
/// bundle — the exact same quote/signature collapsing and remote-image blocking the
/// desktop iframe uses. A strict CSP (`img-src data: blob:`) guarantees the remote
/// tracker can't load even if a vector slips through.
struct ReaderView: UIViewRepresentable {
    @Environment(\.theme) private var theme
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Untrusted email HTML: disable the page's own JavaScript (kills inline
        // `<script>`, `on*=` handlers, `javascript:` URLs). Our driver runs as a
        // `WKUserScript`, which this flag does not affect.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        render(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Re-render on theme change so the body recolors with the app.
        render(webView)
    }

    /// (Re)install the driver as a user script + load the script-free page shell.
    private func render(_ webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: Self.driverJS(for: html),
                                       injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView.loadHTMLString(Self.pageHTML(palette: theme.palette), baseURL: nil)
    }

    /// The page shell: CSP + theme-driven styles + an empty body. No `<script>` —
    /// page JS is disabled and the driver is injected separately. `default-src 'none'`
    /// blocks every remote fetch; `style-src 'unsafe-inline'` keeps inline email
    /// styles; `img-src data: blob:` allows only inlined images.
    private static func pageHTML(palette: ThemePalette) -> String {
        return """
        <!doctype html><html dir="auto"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'; font-src data:;">
        <style>
          body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; margin: 0; padding: 16px 16px 56px; background: \(palette.webBg); color: \(palette.webText); }
          [data-quoted-block], [data-signature-block] { color: \(palette.webMuted); }
          details { margin-top: 12px; }
          summary { color: \(palette.webLink); cursor: pointer; list-style: none; font: 14px -apple-system, system-ui; padding: 4px 0; }
          a { color: \(palette.webLink); }
          blockquote { border-left: 3px solid \(palette.webQuoteBorder); margin: 8px 0; padding-left: 12px; }
          #status { position: fixed; left: 0; right: 0; bottom: 0; background: \(palette.webStatusBg); color: \(palette.webStatusText); font: 12px ui-monospace, monospace; padding: 9px 16px; border-top: 1px solid \(palette.webQuoteBorder); }
        </style></head>
        <body><div id="body"></div><div id="status">rendering…</div></body></html>
        """
    }

    /// The driver: bundle + `processBody` + quote/signature collapse. Injected as a
    /// user script so it runs even with page JS disabled.
    private static func driverJS(for body: String) -> String {
        let bundleJS: String = {
            guard let url = Bundle.main.url(forResource: "email-body", withExtension: "js"),
                  let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return js
        }()
        // JSONSerialization rejects a top-level String (and throws an Obj-C
        // exception try? can't catch), so wrap in an array and unwrap in JS.
        let bodyJSON: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: [body]),
                  let s = String(data: data, encoding: .utf8) else { return "[\"\"]" }
            return s
        }()
        return """
        \(bundleJS)
        ;(function () {
            var SAMPLE = (\(bodyJSON))[0];
            var r = Inbox2EmailBody.processBody(SAMPLE);
            var root = document.getElementById('body');
            root.innerHTML = r.html;
            root.querySelectorAll('[data-quoted-block],[data-signature-block]').forEach(function (el) {
              var details = document.createElement('details');
              var summary = document.createElement('summary');
              summary.textContent = el.matches('[data-signature-block]') ? 'signature ···' : 'quoted text ···';
              el.parentNode.insertBefore(details, el);
              details.appendChild(summary);
              details.appendChild(el);
            });
            document.getElementById('status').textContent =
              'quote: ' + r.hasQuote + '   ·   signature: ' + r.hasSignature + '   ·   remote images blocked: ' + r.blockedCount;
          })();
        """
    }
}
