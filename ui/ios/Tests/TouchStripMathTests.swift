import XCTest

/// Port of `ui/web/src/lib/__tests__/touchStrip.test.js` — the Touch Strip's pure
/// maths (Sources/TouchStrip/TouchStripMath.swift) must match the web strip.
final class TouchStripMathTests: XCTestCase {

    /// A fixed instant in summer time: 12:00 UTC on 2026-07-01.
    private let july = Date(timeIntervalSince1970: 1_782_907_200)

    // MARK: squarify

    func testSquarifyTilesTheBox() {
        let items: [(id: String, value: Double)] = [("a", 6), ("b", 3), ("c", 1)]
        let cells = squarify(items, value: { $0.value }, width: 200, height: 30)
        XCTAssertEqual(cells.reduce(0) { $0 + $1.w * $1.h }, 6000, accuracy: 0.01)
        let a = cells.first { $0.item.id == "a" }!
        XCTAssertEqual(a.w * a.h, 3600, accuracy: 0.01)
        for c in cells {
            XCTAssertLessThanOrEqual(c.x + c.w, 200.0001)
            XCTAssertLessThanOrEqual(c.y + c.h, 30.0001)
        }
    }

    func testSquarifyEmpty() {
        XCTAssertTrue(squarify([Double](), value: { $0 }, width: 100, height: 30).isEmpty)
        XCTAssertTrue(squarify([1.0], value: { $0 }, width: 0, height: 30).isEmpty)
    }

    // MARK: market helpers

    func testChangeBucket() {
        XCTAssertEqual(changeBucket(0.01), "flat")
        XCTAssertEqual(changeBucket(0.5), "up1")
        XCTAssertEqual(changeBucket(-1.5), "down2")
        XCTAssertEqual(changeBucket(4), "up3")
    }

    func testWeightedChange() {
        let q: [(symbol: String, change: Double?)] = [("A", 2), ("B", -1), ("C", nil)]
        XCTAssertEqual(weightedChange(q, weightOf: { $0 == "A" ? 2 : 1 })!, 1, accuracy: 0.0001)
    }

    func testTickerLabel() {
        XCTAssertEqual(tickerLabel("ASML.AS"), "ASML")
        XCTAssertEqual(tickerLabel("BTC-EUR"), "BTC")
        XCTAssertEqual(tickerLabel("^AEX"), "AEX")
    }

    // MARK: time zones

    func testDSTOffsets() {
        XCTAssertEqual(tzOffsetMinutes("Europe/Amsterdam", july), 120)
        XCTAssertEqual(tzOffsetMinutes("America/New_York", july), -240)
        XCTAssertEqual(relativeOffset("America/New_York", "Europe/Amsterdam", july), "−6")
        XCTAssertEqual(relativeOffset("Asia/Kolkata", "Europe/Amsterdam", july), "+3:30")
    }

    func testWorkingSpansWrapMidnight() {
        XCTAssertEqual(workingSpans("America/New_York", "Europe/Amsterdam", july), [[900, 1380]])
        XCTAssertEqual(workingSpans("America/Los_Angeles", "Europe/Amsterdam", july), [[1080, 1440], [0, 120]])
    }

    func testDayPhase() {
        XCTAssertEqual(dayPhase(22 * 60 + 30), .night)
        XCTAssertEqual(dayPhase(5 * 60 + 30), .night)
        XCTAssertEqual(dayPhase(6 * 60 + 30), .dawn)
        XCTAssertEqual(dayPhase(13 * 60), .day)
        XCTAssertEqual(dayPhase(20 * 60), .dusk)
    }

    func testSharedWindow() {
        XCTAssertEqual(sharedWindow(["Europe/Amsterdam", "America/New_York"], "Europe/Amsterdam", july), [900, 1020])
        XCTAssertNil(sharedWindow(["Europe/Amsterdam", "Asia/Tokyo", "America/Los_Angeles"], "Europe/Amsterdam", july))
    }

    // MARK: weather

    private func slot(_ t: String, _ mm: Double) -> RainSlot { RainSlot(time: "2026-09-29T\(t)", mm: mm) }

    func testRainSummary() {
        XCTAssertEqual(rainSummary([slot("14:00", 0), slot("14:15", 0)]), "Dry for 1h")
        XCTAssertEqual(rainSummary([slot("14:00", 0), slot("14:15", 0.4)]), "Rain from 14:15")
        XCTAssertEqual(rainSummary([slot("14:00", 0.6), slot("14:15", 0)]), "Rain until ~14:15")
        XCTAssertNil(rainSummary([]))
    }

    func testWeatherIcon() {
        XCTAssertEqual(weatherIcon(0, true), "sun.max.fill")
        XCTAssertEqual(weatherIcon(0, false), "moon.fill")
        XCTAssertEqual(weatherIcon(63), "cloud.rain")
    }

    // MARK: mergeConfig

    func testMergeConfigKeepsDefaultsAndDropsUnknownWidgets() throws {
        let json = #"{"items":["stocks","bogus"],"crypto":null,"options":{"crypto_currency":"USD"}}"#
        let saved = try JSONDecoder().decode(SavedStrip.self, from: Data(json.utf8))
        let c = mergeConfig(saved)
        XCTAssertEqual(c.items, [.stocks])
        XCTAssertEqual(c.crypto, ["BTC", "ETH", "SOL"])
        XCTAssertEqual(c.options, StripOptions(stock_size: .equal, crypto_currency: "USD"))
    }

    func testNeverSavedLayoutIsNotSaved() throws {
        let json = #"{"items":null,"clocks":null,"places":null,"stocks":null,"crypto":null,"feeds":null,"options":null}"#
        XCTAssertFalse(try JSONDecoder().decode(SavedStrip.self, from: Data(json.utf8)).hasSaved)
    }
}
