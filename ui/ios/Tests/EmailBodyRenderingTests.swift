import XCTest
import WebKit

/// On-device rendering harness for the email body engine. The web/desktop app and
/// the iOS/Android WebViews all render through the same shipped `email-body.js`
/// bundle; this loads that exact bundle into a real `WKWebView` and runs every
/// fixture in `fixtures/email/` (flattened into `fixtures.gen.json` by
/// `bin/gen-email-fixtures`) through `processBody()`, asserting the same outcomes
/// the JS harness checks. It proves the bundle behaves correctly when executed by
/// WebKit on this platform — catching a stale/broken embedded bundle or a WebKit
/// engine difference that the Node/jsdom suite can't see.
///
/// Self-contained: it depends only on the bundle + the corpus JSON (both bundled as
/// test resources), never on the app module — so it runs in the fast hostless test
/// target alongside the Kokoro logic tests.
final class EmailBodyRenderingTests: XCTestCase {

    // MARK: Fixture model (mirrors fixtures.gen.json / manifest.json)

    private struct Expect: Decodable {
        var hasQuote: Bool?
        var hasSignature: Bool?
        var blocksRemote: Bool?
        var unwrapsPre: Bool?
        var contains: [String]?
        var notContains: [String]?
    }
    private struct Case: Decodable {
        let name: String
        let title: String
        let html: String
        let expect: Expect
    }
    private struct Corpus: Decodable { let cases: [Case] }

    private struct Result: Decodable {
        var hasQuote: Bool?
        var hasSignature: Bool?
        var blockedCount: Int?
        var html: String?
        var error: String?
    }

    // MARK: WebView plumbing

    private var webView: WKWebView!
    private var bundleJS: String!
    private var pending: XCTestExpectation?
    private var lastResult: Result?

    override func setUpWithError() throws {
        let bundle = Bundle(for: type(of: self))
        let jsURL = try XCTUnwrap(bundle.url(forResource: "email-body", withExtension: "js"),
                                  "email-body.js missing from the test bundle — check project.yml resources")
        bundleJS = try String(contentsOf: jsURL, encoding: .utf8)

        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(Handler(self), name: "result")
        config.userContentController = ucc
        webView = WKWebView(frame: .init(x: 0, y: 0, width: 390, height: 800), configuration: config)
    }

    override func tearDownWithError() throws {
        webView = nil
        bundleJS = nil
    }

    /// Bridges the page's single `result` message back to the waiting test.
    private final class Handler: NSObject, WKScriptMessageHandler {
        weak var owner: EmailBodyRenderingTests?
        init(_ o: EmailBodyRenderingTests) { owner = o }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let json = message.body as? String, let data = json.data(using: .utf8) else { return }
            owner?.lastResult = try? JSONDecoder().decode(Result.self, from: data)
            owner?.pending?.fulfill()
        }
    }

    /// Load the bundle + one fixture and return what `processBody` produced. The page
    /// posts its result synchronously at parse time (no rAF / layout), so this works
    /// even though the web view is never on screen.
    private func process(_ html: String) throws -> Result {
        let sample = jsString(html)
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="img-src data: blob:;"></head>
        <body><script>\(bundleJS!)</script><script>
          try {
            var r = Inbox2EmailBody.processBody(\(sample));
            webkit.messageHandlers.result.postMessage(JSON.stringify({
              hasQuote: r.hasQuote, hasSignature: r.hasSignature,
              blockedCount: r.blockedCount, html: r.html
            }));
          } catch (e) {
            webkit.messageHandlers.result.postMessage(JSON.stringify({ error: String(e) }));
          }
        </script></body></html>
        """
        lastResult = nil
        let exp = expectation(description: "processBody")
        pending = exp
        webView.loadHTMLString(page, baseURL: nil)
        wait(for: [exp], timeout: 10)
        return try XCTUnwrap(lastResult, "no result posted from the web view")
    }

    /// Encode a Swift string as a JS string literal for safe splicing into the page.
    private func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast()) // strip the wrapping [ ]
    }

    private func loadCorpus() throws -> [Case] {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "fixtures.gen", withExtension: "json"),
                                "fixtures.gen.json missing — run bin/gen-email-fixtures and check project.yml")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url)).cases
    }

    // MARK: The harness

    func testEveryFixtureRendersThroughTheShippedBundle() throws {
        let cases = try loadCorpus()
        XCTAssertGreaterThan(cases.count, 0, "corpus is empty")

        for c in cases {
            let r = try process(c.html)
            XCTAssertNil(r.error, "[\(c.name)] processBody threw: \(r.error ?? "")")
            let html = r.html ?? ""

            XCTAssertEqual(r.hasQuote, c.expect.hasQuote ?? false, "[\(c.name)] hasQuote — \(c.title)")
            XCTAssertEqual(r.hasSignature, c.expect.hasSignature ?? false, "[\(c.name)] hasSignature — \(c.title)")

            if c.expect.blocksRemote == true {
                XCTAssertGreaterThan(r.blockedCount ?? 0, 0, "[\(c.name)] expected remote content to be blocked")
            } else {
                XCTAssertEqual(r.blockedCount ?? 0, 0, "[\(c.name)] expected no remote content blocked")
            }

            if c.expect.unwrapsPre == true {
                XCTAssertFalse(html.range(of: "<pre", options: .caseInsensitive) != nil,
                               "[\(c.name)] expected the <pre> wrapper to be unwrapped")
            }

            // Universal privacy invariant: never a LIVE remote image src in the output.
            // The leading space matches only a live ` src="http…"` attribute, not the
            // stashed `data-blocked-src="http…"` (hyphen-prefixed) that holds the
            // original for restore.
            XCTAssertNil(html.range(of: " src=\"http", options: .caseInsensitive),
                         "[\(c.name)] left a live remote image src in the rendered HTML")

            for needle in c.expect.contains ?? [] {
                XCTAssertTrue(html.contains(needle), "[\(c.name)] output should contain: \(needle)")
            }
            for needle in c.expect.notContains ?? [] {
                XCTAssertFalse(html.contains(needle), "[\(c.name)] output should NOT contain: \(needle)")
            }
        }
    }
}
