import XCTest
import WebKit

/// Layout harness for the email reader: proves an email body, rendered through the
/// app's real `EmailReaderCSS` + the shipped `email-body.js` bundle, FITS a phone
/// viewport — no horizontal overflow. Desktop emails routinely pin a 600px width
/// (Temu pins it with `min-width`), which on a phone laid out the body at 600px and
/// clipped the right side; Gmail reflows it. This measures the rendered geometry of
/// every element and fails if anything spills past the viewport.
///
/// Self-contained (bundle + corpus as test resources, EmailReaderCSS compiled in) so
/// it runs in the fast hostless test target. Mirrors EmailBodyRenderingTests.
final class EmailBodyLayoutTests: XCTestCase {

    private struct Expect: Decodable { var noOverflow: Bool?; var noShrink: Bool?; var proseFullSize: Bool? }
    private struct Case: Decodable { let name: String; let title: String; let html: String; let expect: Expect }
    private struct Corpus: Decodable { let cases: [Case] }
    private struct Metrics: Decodable {
        var viewport: Double?; var maxRight: Double?; var scale: Double?
        /// The effective (accumulated-transform) scale the first paragraph is painted at.
        var proseScale: Double?
        var error: String?
    }

    // A phone-class viewport. The WebView is sized to this and the page uses
    // width=device-width, so layout happens at this width.
    private let viewportWidth: CGFloat = 390

    private var webView: WKWebView!
    private var bundleJS: String!
    private var pending: XCTestExpectation?
    private var lastMetrics: Metrics?

    override func setUpWithError() throws {
        let bundle = Bundle(for: type(of: self))
        let jsURL = try XCTUnwrap(bundle.url(forResource: "email-body", withExtension: "js"))
        bundleJS = try String(contentsOf: jsURL, encoding: .utf8)

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(Handler(self), name: "metrics")
        config.userContentController = ucc
        webView = WKWebView(frame: .init(x: 0, y: 0, width: viewportWidth, height: 1400), configuration: config)
    }

    override func tearDownWithError() throws { webView = nil; bundleJS = nil }

    private final class Handler: NSObject, WKScriptMessageHandler {
        weak var owner: EmailBodyLayoutTests?
        init(_ o: EmailBodyLayoutTests) { owner = o }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let json = message.body as? String, let data = json.data(using: .utf8) else { return }
            owner?.lastMetrics = try? JSONDecoder().decode(Metrics.self, from: data)
            owner?.pending?.fulfill()
        }
    }

    /// Render `html` through the REAL reader CSS + bundle, then report the viewport
    /// width and the furthest-right edge of any content element. Measured after a
    /// layout pass so reflow has settled.
    private func measure(_ html: String) throws -> Metrics {
        let sample = jsString(html)
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="img-src data: blob:;">
        <style>\(EmailReaderCSS.css)</style></head>
        <body><div id="body"></div>
        <script>\(bundleJS!)</script>
        <script>
          window.onerror = function (m) {
            try { webkit.messageHandlers.metrics.postMessage(JSON.stringify({ error: 'onerror: ' + m })); } catch (e) {}
          };
          try {
            var SAMPLE = \(sample);
            // Mirror the REAL reader host (MessageBodyWebView): re-inject the email's own
            // <style> blocks — the responsive media queries usually live in <head>, which
            // processBody() drops. Without them, a responsive email collapses back into its
            // raw fixed-width tables and renders differently than on device — so the harness
            // must do this too or it silently passes bugs that only the real host hits.
            // @import + remote url() are stripped (privacy / CSP parity).
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
            // Height backstop (matches the host) — last stylesheet wins.
            (function () {
              var fit = document.createElement('style');
              fit.textContent = '\(EmailReaderCSS.fitBackstopCss)';
              document.head.appendChild(fit);
            })();
            var root = document.getElementById('body');
            var r = Inbox2EmailBody.processBody(SAMPLE);
            root.innerHTML = r.html;
            \(EmailReaderCSS.fitJS)
            var scale = window.__fitEmail();
            // Reading layout geometry forces a synchronous reflow — no need for rAF,
            // which doesn't fire in an offscreen WKWebView. getBoundingClientRect reports
            // true geometry even under overflow:hidden, so a 600px table laid out on a
            // 390px viewport reads maxRight ~600 — i.e. it overflowed.
            void document.body.offsetHeight;
            var maxRight = 0;
            root.querySelectorAll('*').forEach(function (el) {
              var rect = el.getBoundingClientRect();
              if (rect.width > 0 && rect.right > maxRight) maxRight = rect.right;
            });
            // How large the body text is actually painted: getBoundingClientRect includes
            // every ancestor transform, offsetWidth doesn't — their ratio is the accumulated
            // scale on that element. 1 = the prose was left alone.
            var proseScale = 1, p = root.querySelector('p');
            if (p && p.offsetWidth) proseScale = p.getBoundingClientRect().width / p.offsetWidth;
            webkit.messageHandlers.metrics.postMessage(JSON.stringify({
              viewport: document.documentElement.clientWidth, maxRight: maxRight,
              scale: scale, proseScale: proseScale
            }));
          } catch (e) {
            webkit.messageHandlers.metrics.postMessage(JSON.stringify({ error: String(e) }));
          }
        </script></body></html>
        """
        lastMetrics = nil
        let exp = expectation(description: "metrics")
        pending = exp
        webView.loadHTMLString(page, baseURL: nil)
        wait(for: [exp], timeout: 10)
        return try XCTUnwrap(lastMetrics)
    }

    private func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())
    }

    private func loadCorpus() throws -> [Case] {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "fixtures.gen", withExtension: "json"))
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url)).cases
    }

    func testReflowableFixturesDoNotOverflowThePhoneViewport() throws {
        let cases = try loadCorpus().filter { $0.expect.noOverflow == true }
        XCTAssertGreaterThan(cases.count, 0, "no fixtures flagged noOverflow — check the manifest")

        for c in cases {
            let m = try measure(c.html)
            XCTAssertNil(m.error, "[\(c.name)] render threw: \(m.error ?? "")")
            let viewport = try XCTUnwrap(m.viewport)
            let maxRight = try XCTUnwrap(m.maxRight)
            // Allow 1px for sub-pixel rounding. Anything wider is a clipped/overflowing email.
            XCTAssertLessThanOrEqual(maxRight, viewport + 1,
                "[\(c.name)] overflowed: content reaches \(maxRight)px on a \(viewport)px viewport — \(c.title)")
        }
    }

    /// Regression guard for the prose scale-down bug: an ordinary text email (flowing
    /// prose, or a plain-text body in `white-space:pre-wrap`) must render at its full
    /// width, NOT be shrunk to a tiny strip. The old fit pass measured `width:max-content`,
    /// which unwrapped every paragraph onto one line and reported a giant "natural width" —
    /// scaling the whole body down to an unreadable thumbnail. `noShrink` fixtures assert
    /// the fit pass leaves them at scale ≈ 1.
    func testProseFixturesAreNotScaledDown() throws {
        let cases = try loadCorpus().filter { $0.expect.noShrink == true }
        XCTAssertGreaterThan(cases.count, 0, "no fixtures flagged noShrink — check the manifest")

        for c in cases {
            let m = try measure(c.html)
            XCTAssertNil(m.error, "[\(c.name)] render threw: \(m.error ?? "")")
            let scale = try XCTUnwrap(m.scale)
            XCTAssertEqual(scale, 1.0, accuracy: 0.01,
                "[\(c.name)] was scaled to \(scale) — flowing text should wrap and render full width, not shrink — \(c.title)")
        }
    }

    /// Regression guard for the unreadable-thumbnail bug: an email carrying ONE
    /// un-reflowable wide element (a 15-column financial table in a quoted chain) must
    /// have that element scaled ALONE. Scaling the whole body to fit it — the old
    /// strategy — took the surrounding prose to ~0.2, which Gmail visibly doesn't do.
    func testProseStaysFullSizeBesideAnUltraWideElement() throws {
        let cases = try loadCorpus().filter { $0.expect.proseFullSize == true }
        XCTAssertGreaterThan(cases.count, 0, "no fixtures flagged proseFullSize — check the manifest")

        for c in cases {
            let m = try measure(c.html)
            XCTAssertNil(m.error, "[\(c.name)] render threw: \(m.error ?? "")")
            let proseScale = try XCTUnwrap(m.proseScale)
            let scale = try XCTUnwrap(m.scale)
            XCTAssertEqual(proseScale, 1.0, accuracy: 0.01,
                "[\(c.name)] prose painted at \(proseScale)× — only the un-reflowable element should scale — \(c.title)")
            XCTAssertLessThan(scale, 1.0,
                "[\(c.name)] nothing was scaled — the wide element should have been fitted — \(c.title)")
        }
    }
}
