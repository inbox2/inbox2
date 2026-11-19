import XCTest

/// The rules that decide whether the phone goes off. Both failure directions are
/// silent in the field — a meeting with no alarm looks identical to one you slept
/// through, and a false alarm only shows up as an alarm at the wrong moment — so
/// they're pinned here rather than trusted to a device test.
final class MeetingAlarmPlanTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)   // fixed clock
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// An event starting `minutes` from the test's `now`.
    private func event(_ id: String, inMinutes minutes: Double, allDay: Bool = false,
                       attendeesJSON: String? = nil) -> CalendarEvent {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEvent(
            id: id, accountKey: "acc_1", title: "Standup \(id)",
            startAt: Self.iso.string(from: start),
            endAt: Self.iso.string(from: start.addingTimeInterval(1800)),
            allDay: allDay, location: nil, organizerName: nil, detail: nil,
            calendarColorHex: nil, calendarName: nil, metadataJSON: attendeesJSON)
    }

    private func plan(_ events: [CalendarEvent], lead: Int = 5,
                      muted: Set<String> = [], mine: Set<String> = [], limit: Int = 32) -> [MeetingAlarm] {
        MeetingAlarmPlan.alarms(for: events, leadMinutes: lead, now: now,
                                muted: muted, myEmails: mine, limit: limit)
    }

    func testFiresAtLeadTimeBeforeStart() {
        let alarms = plan([event("a", inMinutes: 60)], lead: 5)
        XCTAssertEqual(alarms.count, 1)
        XCTAssertEqual(alarms[0].eventKey, "a")
        XCTAssertEqual(alarms[0].fireAt.timeIntervalSince(now), 55 * 60, accuracy: 1)
        XCTAssertTrue(alarms[0].body.hasPrefix("Starts in 5 min"), alarms[0].body)
    }

    /// The lead window has already passed (or the meeting is under way): scheduling
    /// it would fire on the next foreground, every foreground.
    func testSkipsMeetingsInsideTheLeadWindowOrAlreadyStarted() {
        XCTAssertTrue(plan([event("soon", inMinutes: 3)], lead: 5).isEmpty)
        XCTAssertTrue(plan([event("running", inMinutes: -10)], lead: 5).isEmpty)
    }

    func testSkipsAllDayAndMutedMeetings() {
        XCTAssertTrue(plan([event("holiday", inMinutes: 120, allDay: true)]).isEmpty)
        XCTAssertTrue(plan([event("cancelled-irl", inMinutes: 120)], muted: ["cancelled-irl"]).isEmpty)
    }

    func testSkipsMeetingsYouDeclinedButNotOnesYouAccepted() {
        let declined = #"{"attendees":[{"email":"ME@x.com","responseStatus":"declined"}]}"#
        let accepted = #"{"attendees":[{"email":"me@x.com","responseStatus":"accepted"}]}"#
        let other = #"{"attendees":[{"email":"someone@x.com","responseStatus":"declined"}]}"#
        let mine: Set<String> = ["me@x.com"]

        // Matched case-insensitively — providers echo back whatever case was typed.
        XCTAssertTrue(plan([event("d", inMinutes: 60, attendeesJSON: declined)], mine: mine).isEmpty)
        XCTAssertEqual(plan([event("a", inMinutes: 60, attendeesJSON: accepted)], mine: mine).count, 1)
        XCTAssertEqual(plan([event("o", inMinutes: 60, attendeesJSON: other)], mine: mine).count, 1)
    }

    /// iOS drops pending local notifications past 64, so the cap has to keep the
    /// NEAREST meetings — the agenda read is start-ordered, so first N is right.
    func testCapsAtLimitKeepingTheNearestMeetings() {
        let events = (1...10).map { event("e\($0)", inMinutes: Double($0) * 60) }
        let alarms = plan(events, limit: 3)
        XCTAssertEqual(alarms.map(\.eventKey), ["e1", "e2", "e3"])
    }
}
