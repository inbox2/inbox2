import Foundation
import SwiftUI

/// Calendar status values stored by the engine — single source for the SQL filters.
enum CalendarStatusValue {
    /// `calendar_events.status` — a cancelled occurrence is hidden everywhere.
    static let eventCancelled = "cancelled"
    /// `calendars.status` — only active calendars are listed/toggled.
    static let calendarActive = "active"
}

/// One meeting participant, parsed from the `attendees` array inside an event's
/// `metadata` JSON blob (populated identically by the Google + Microsoft syncers).
struct EventAttendee: Hashable {
    let email: String?
    let name: String?
    let responseStatus: String?   // accepted | declined | tentative | needsAction
    let isOrganizer: Bool

    /// Best human label — display name, else the email, else a placeholder.
    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let e = email, !e.isEmpty { return e }
        return "Unknown"
    }

    /// SF Symbol + tint cue for the RSVP state, mirroring the RSVP buttons.
    var statusIcon: String {
        switch responseStatus {
        case "accepted":    return "checkmark.circle.fill"
        case "declined":    return "xmark.circle.fill"
        case "tentative":   return "questionmark.circle.fill"
        default:            return "circle"
        }
    }
}

/// A meeting you can click straight into: the conferencing link plus whose it is.
struct EventMeeting {
    let url: URL
    let label: String   // "Google Meet" / "Zoom" / "meeting"

    /// Bundled brand logo (`Resources/mtg-*.png`, rendered from the web
    /// `meetingProvider.js` glyphs). Nil for an unknown host.
    var logo: String? {
        switch label {
        case "Zoom": return "mtg-zoom"
        case "Google Meet": return "mtg-meet"
        case "Microsoft Teams": return "mtg-teams"
        case "Webex": return "mtg-webex"
        default: return nil
        }
    }
}

/// Known conferencing hosts → brand name. Same table as the web
/// `meetingProvider.js` HOSTS — first match wins.
enum MeetingHosts {
    private static let table = [
        ("zoom.us", "Zoom"), ("zoom.com", "Zoom"),
        ("teams.microsoft.com", "Microsoft Teams"), ("teams.live.com", "Microsoft Teams"),
        ("meet.google.com", "Google Meet"), ("webex.com", "Webex"),
    ]

    static func label(_ url: String) -> String? {
        let hay = url.lowercased()
        return table.first { hay.contains($0.0) }?.1
    }
}

/// A calendar event read from local SQLite (`calendar_events` joined to
/// `calendars` for the color/name). Times are ISO-8601 strings, mirroring the
/// desktop useCalendarEvents read.
struct CalendarEvent: Identifiable, Hashable {
    let id: String            // calendar_events.key
    let accountKey: String    // calendar_events.account_key (for RSVP write-back)
    let title: String
    let startAt: String       // ISO-8601
    let endAt: String
    let allDay: Bool
    let location: String?
    let organizerName: String?
    let organizerEmail: String?
    let detail: String?       // description
    let calendarColorHex: String?
    let calendarName: String?
    /// Raw `calendar_events.metadata` JSON (attendees + provider web link). Parsed
    /// lazily via `attendees` so the agenda/month-grid reads don't pay for it.
    let metadataJSON: String?
    /// The event's calendar is writable (Google owner/writer, Microsoft canEdit) — so
    /// Edit/Delete are allowed. Read-only calendars (shared/subscribed/holidays) are
    /// false; the provider 403s on mutation, so the UI hides those actions.
    let calendarWritable: Bool

    // Parsed once at construction — `parse` is expensive (it can allocate a
    // formatter), and these are read on every grouping/sort/row render, so caching
    // them keeps the agenda + chart cheap enough to scroll smoothly.
    let start: Date?
    let end: Date?
    /// Local start-of-day, for agenda grouping.
    let dayKey: Date

    init(id: String, accountKey: String, title: String, startAt: String, endAt: String,
         allDay: Bool, location: String?, organizerName: String?, organizerEmail: String? = nil,
         detail: String?, calendarColorHex: String?, calendarName: String?, metadataJSON: String? = nil,
         calendarWritable: Bool = true) {
        self.id = id
        self.accountKey = accountKey
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.allDay = allDay
        self.location = location
        self.organizerName = organizerName
        self.organizerEmail = organizerEmail
        self.detail = detail
        self.calendarColorHex = calendarColorHex
        self.calendarName = calendarName
        self.metadataJSON = metadataJSON
        self.calendarWritable = calendarWritable
        let s = RelativeTime.parse(startAt)
        self.start = s
        self.end = RelativeTime.parse(endAt)
        self.dayKey = Calendar.current.startOfDay(for: s ?? Date(timeIntervalSince1970: 0))
    }

    /// "10:00" — the start time (or "All day").
    /// True once the event has ended — drives the agenda's faded "already happened"
    /// look. All-day events use their end-of-day, so today's don't read as past.
    var isPast: Bool {
        guard let e = end ?? start else { return false }
        return e < Date()
    }

    var startTimeLabel: String {
        guard !allDay, let s = start else { return "All day" }
        return CalendarClock.formatter.string(from: s)
    }
    /// "– 10:30" end time, empty for all-day or zero-length.
    var endTimeLabel: String {
        guard !allDay, let s = start, let e = end, e > s else { return "" }
        return CalendarClock.formatter.string(from: e)
    }
    /// "10:00 – 10:30" / "All day" — full range for the detail sheet.
    var rangeLabel: String {
        if allDay { return "All day" }
        let end = endTimeLabel
        return end.isEmpty ? startTimeLabel : "\(startTimeLabel) – \(end)"
    }

    /// Organizer to show — display name when present, else the email. Most Google
    /// imports carry only the email (name is null), so the bare name check hid the row.
    var organizerLabel: String? {
        if let n = organizerName, !n.isEmpty { return n }
        if let e = organizerEmail, !e.isEmpty { return e }
        return nil
    }

    /// Parsed `metadata` blob — attendees and the provider's conference link.
    private var metadata: [String: Any]? {
        guard let json = metadataJSON, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Where to tap to get into this meeting — the iOS mirror of the web
    /// `detectMeeting`. A structured link recorded by the provider itself
    /// (`metadata.conference`, written by both syncers) wins; otherwise scan the
    /// free text, which is where an emailed invite or a pasted Zoom link puts it.
    /// Nil for anything with no way in (a lunch, a room booking).
    var meeting: EventMeeting? {
        let conf = metadata?["conference"] as? [String: Any]
        if let raw = conf?["url"] as? String, let url = URL(string: raw) {
            return EventMeeting(url: url, label: MeetingHosts.label(raw) ?? (conf?["label"] as? String) ?? "meeting")
        }
        // Descriptions arrive as HTML — decode the ampersand or a Zoom link loses
        // its `?pwd=` half.
        let hay = [location, detail, title].compactMap { $0 }.joined(separator: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        for raw in Linkify.urls(in: hay) {
            guard let label = MeetingHosts.label(raw), let url = URL(string: raw) else { continue }
            return EventMeeting(url: url, label: label)
        }
        return nil
    }

    /// Meeting participants parsed from `metadataJSON`. Both syncers emit
    /// `{ "attendees": [{ email, name, responseStatus, organizer }] }` — MS omits
    /// `organizer` (falls back to false). Parsed on demand, only the detail sheet calls it.
    var attendees: [EventAttendee] {
        guard let arr = metadata?["attendees"] as? [[String: Any]] else { return [] }
        return arr.map { a in
            EventAttendee(
                email: a["email"] as? String,
                name: a["name"] as? String,
                responseStatus: a["responseStatus"] as? String,
                isOrganizer: a["organizer"] as? Bool ?? false
            )
        }
    }
}

/// Turns bare http(s) URLs in user-authored free text (event notes, location)
/// into tappable links — the iOS mirror of the web `Linkify` component. Trailing
/// sentence punctuation is kept outside the link so "see https://x.com." doesn't
/// capture the period.
enum Linkify {
    private static let urlRE = try! NSRegularExpression(
        pattern: "https?://[^\\s<]+[^\\s<.,:;!?\"')\\]}]", options: [.caseInsensitive])

    /// Bare http(s) URLs in `text`, in order — the same scan the link runs use.
    static func urls(in text: String) -> [String] {
        let ns = text as NSString
        return urlRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// `text` as an AttributedString with URL runs linked + tinted/underlined.
    /// `Text(_:)` renders the `.link` runs tappable (opens via the environment).
    static func attributed(_ text: String, color: Color) -> AttributedString {
        var attr = AttributedString(text)
        let ns = text as NSString
        let matches = urlRE.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard let url = URL(string: ns.substring(with: m.range)),
                  let range = Range(m.range, in: attr) else { continue }
            attr[range].link = url
            attr[range].foregroundColor = color
            attr[range].underlineStyle = .single
        }
        return attr
    }
}

/// Friendly day-section headers for the agenda ("Today", "Tomorrow", "Mon 9 Jun").
enum DayHeader {
    // Shared formatters — allocating a DateFormatter per section header is costly.
    static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMM"; return f
    }()
    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, d MMM yyyy"; return f
    }()

    /// In the calendar's shown zone (CalendarZone sets `CalendarClock.formatter.timeZone`).
    static func label(_ day: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = CalendarClock.formatter.timeZone
        dayMonth.timeZone = cal.timeZone
        dayMonthYear.timeZone = cal.timeZone
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInTomorrow(day) { return "Tomorrow" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let sameYear = cal.isDate(day, equalTo: Date(), toGranularity: .year)
        return (sameYear ? dayMonth : dayMonthYear).string(from: day)
    }
}
