import XCTest

/// Recipient autocomplete is ranked, not filtered — a wrong order is invisible except
/// as "why is this person from four years ago at the top?", which is exactly the bug
/// these pin.
final class ContactRankingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)   // 2026-02-02, fixed clock

    /// An ISO timestamp `days` before the test's `now`.
    private func ago(_ days: Double) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: now.addingTimeInterval(-days * 86_400))
    }

    private func rank(_ rows: [(from: String, to: String, updatedAt: String)]) -> [Contact] {
        ContactRanking.rank(rows, now: now)
    }

    /// Where an address lands in the ranking. Assertions compare positions rather than
    /// `.first`, because the account's own address is on every row and so always wins —
    /// pre-existing behaviour, and not what these tests are about.
    private func rank(_ rows: [(from: String, to: String, updatedAt: String)], of email: String) -> Int {
        rank(rows).firstIndex { $0.email == email } ?? Int.max
    }

    /// The reported bug: sheer lifetime volume from years ago outranking someone
    /// you actually correspond with now.
    func testRecentCorrespondentOutranksHigherVolumeAncientOne() {
        var rows: [(from: String, to: String, updatedAt: String)] = []
        rows += (0..<20).map { _ in (from: "old@x.com", to: "me@x.com", updatedAt: ago(1500)) }
        rows += (0..<5).map { _ in (from: "current@x.com", to: "me@x.com", updatedAt: ago(10)) }

        XCTAssertLessThan(rank(rows, of: "current@x.com"), rank(rows, of: "old@x.com"))
        XCTAssertEqual(rank(rows).first(where: { $0.email == "old@x.com" })?.total, 20,
                       "`total` must stay the raw count — Settings shows it as N×")
    }

    /// Recency alone isn't enough either: one message yesterday must not beat a
    /// steady correspondent within the same bucket.
    func testFrequencyStillBreaksTiesWithinABucket() {
        var rows: [(from: String, to: String, updatedAt: String)] = []
        rows += (0..<8).map { _ in (from: "steady@x.com", to: "me@x.com", updatedAt: ago(20)) }
        rows += [(from: "oneoff@x.com", to: "me@x.com", updatedAt: ago(1))]

        XCTAssertLessThan(rank(rows, of: "steady@x.com"), rank(rows, of: "oneoff@x.com"))
    }

    /// A conversation with no usable timestamp still contributes — it just sorts last.
    func testMissingTimestampRanksLastButIsKept() {
        let rows: [(from: String, to: String, updatedAt: String)] = [
            (from: "unknown@x.com", to: "me@x.com", updatedAt: ""),
            (from: "recent@x.com", to: "me@x.com", updatedAt: ago(5)),
        ]
        XCTAssertLessThan(rank(rows, of: "recent@x.com"), rank(rows, of: "unknown@x.com"))
        XCTAssertTrue(rank(rows).contains { $0.email == "unknown@x.com" })
    }

    /// Names are taken from whichever appearance carries the fuller one.
    func testUpgradesToTheRicherName() {
        let rows: [(from: String, to: String, updatedAt: String)] = [
            (from: "dana@x.com", to: "me@x.com", updatedAt: ago(5)),
            (from: "Dana Lee <dana@x.com>", to: "me@x.com", updatedAt: ago(4)),
        ]
        XCTAssertEqual(rank(rows).first(where: { $0.email == "dana@x.com" })?.name, "Dana Lee")
    }
}
