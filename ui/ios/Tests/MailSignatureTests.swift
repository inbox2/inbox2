import XCTest

final class MailSignatureTests: XCTestCase {
    private let sig = MailSignature(id: "sig_a", html: "<p>Wesley<br>Lalaaji</p>", text: "-- \nWesley\nLalaaji")

    func testNoSignatureLeavesThePlainBody() {
        let b = MailSignature.body(plain: "Hi", signature: nil)
        XCTAssertEqual(b.plain, "Hi")
        XCTAssertNil(b.html)
    }

    func testAddsTheSignatureAndEscapesTheText() {
        let b = MailSignature.body(plain: "a < b\nok\n\nBye", signature: sig)
        XCTAssertEqual(b.plain, "a < b\nok\n\nBye\n\n-- \nWesley\nLalaaji")
        XCTAssertEqual(b.html, "<p>a &lt; b<br>ok</p><p>Bye</p><br><div data-signature=\"sig_a\"><p>Wesley<br>Lalaaji</p></div>")
        XCTAssertEqual(sig.previewText, "Wesley\nLalaaji")
    }

    func testDecodesTheAppliedMap() throws {
        let json = #"{"applied":{"wesley@lalaaji.com":{"id":"sig_a","html":"<p>W</p>","text":"-- \nW"}}}"#
        struct R: Decodable { let applied: [String: MailSignature] }
        let r = try JSONDecoder().decode(R.self, from: Data(json.utf8))
        XCTAssertEqual(r.applied["wesley@lalaaji.com"]?.id, "sig_a")
    }
}
