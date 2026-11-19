import XCTest

/// Where the Join button points. Both failure directions are quiet — a missing
/// button reads as "this meeting has no link", and a wrong one drops you into the
/// wrong call — so the two sources (the provider's own `conference` blob vs the
/// free-text scan) are pinned here.
final class EventMeetingTests: XCTestCase {

    private func event(location: String? = nil, detail: String? = nil,
                       title: String = "Standup", metadataJSON: String? = nil) -> CalendarEvent {
        CalendarEvent(
            id: "evt_1", accountKey: "acc_1", title: title,
            startAt: "2026-09-09T09:00:00Z", endAt: "2026-09-09T09:30:00Z",
            allDay: false, location: location, organizerName: nil, detail: detail,
            calendarColorHex: nil, calendarName: nil, metadataJSON: metadataJSON)
    }

    /// The synced conference link wins over anything in the body — a forwarded
    /// invite often carries a mangled copy of the URL in its text.
    func testConferenceMetadataWins() {
        let meta = #"{"conference":{"url":"https://meet.google.com/abc-defg-hij","label":"Google Meet"}}"#
        let m = event(detail: "old link: https://zoom.us/j/1", metadataJSON: meta).meeting
        XCTAssertEqual(m?.url.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(m?.label, "Google Meet")
    }

    /// An emailed invite puts the link in the location or the notes — and the notes
    /// arrive as HTML, so the entity-encoded ampersand must survive (a Zoom link
    /// loses its `?pwd=` half otherwise).
    func testFreeTextScanKeepsQueryString() {
        let m = event(detail: "Dial in: https://zoom.us/j/99?pwd=x&amp;uname=y.").meeting
        XCTAssertEqual(m?.url.absoluteString, "https://zoom.us/j/99?pwd=x&uname=y")
        XCTAssertEqual(m?.label, "Zoom")
    }

    func testTeamsLocation() {
        XCTAssertEqual(event(location: "https://teams.microsoft.com/l/meetup-join/19%3a1").meeting?.label,
                       "Microsoft Teams")
    }

    /// A lunch has no way in — no button.
    func testNoMeetingLink() {
        XCTAssertNil(event(location: "Kitchen", detail: "See https://example.com/menu").meeting)
    }
}
