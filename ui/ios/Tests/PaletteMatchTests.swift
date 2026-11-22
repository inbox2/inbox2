import XCTest

/// The iPad command palette's ranking (Sources/Models/PaletteMatch.swift).
final class PaletteMatchTests: XCTestCase {
    func testEveryCharacterInOrder() {
        XCTAssertNotNil(PaletteMatch.score("nm", "New message"))
        XCTAssertNil(PaletteMatch.score("um", "Menu"))  // out of order
        XCTAssertNil(PaletteMatch.score("xyz", "Calendar"))
        XCTAssertEqual(PaletteMatch.score("", "Anything"), 0)
    }

    func testWordStartsAndPrefixesRankFirst() {
        let prefix = PaletteMatch.score("cal", "Calendar")!
        let inside = PaletteMatch.score("cal", "Change the calendar time zone")!
        XCTAssertGreaterThan(prefix, inside)
        let wordStarts = PaletteMatch.score("nm", "New message")!
        let scattered = PaletteMatch.score("nm", "Inbox summary")!
        XCTAssertGreaterThan(wordStarts, scattered)
    }
}
