import Foundation

/// A repeating event's rule as the event sheet edits it, and the RFC 5545
/// RRULE body it saves as (`FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2`, no `RRULE:`).
/// Mirrors web `lib/recurrence.js`; the Rust core turns the body into Google's
/// `recurrence` or Graph's pattern + range.
struct RepeatRule: Equatable {
    enum Freq: String, CaseIterable, Identifiable {
        case none, daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY"
        /// A rule set elsewhere that the sheet can't draw (2nd Tuesday, …): kept as is.
        case custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "Does not repeat"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .yearly: "Yearly"
            case .custom: "Custom (as set elsewhere)"
            }
        }
        var unit: String {
            switch self {
            case .daily: "day"
            case .weekly: "week"
            case .monthly: "month"
            case .yearly: "year"
            default: ""
            }
        }
    }
    enum Ends: String, CaseIterable, Identifiable {
        case never, on, after
        var id: String { rawValue }
        var label: String { self == .never ? "Never" : self == .on ? "On date" : "After" }
    }

    /// Monday first. `weekday` is Calendar's (1 = Sunday).
    static let weekdays: [(code: String, short: String, weekday: Int)] = [
        ("MO", "M", 2), ("TU", "T", 3), ("WE", "W", 4), ("TH", "T", 5),
        ("FR", "F", 6), ("SA", "S", 7), ("SU", "S", 1),
    ]

    var freq: Freq = .none
    var interval = 1
    /// Weekly days; empty = the start's own weekday.
    var days: Set<String> = []
    var ends: Ends = .never
    var until = Calendar.current.startOfDay(for: Date())
    var count = 2
    /// The untouched body of a `.custom` rule.
    var customRule: String?
    /// WKST as read, kept on rebuild: it decides which weeks an every-N-weeks
    /// series falls in, and the sheet has no control for it.
    var wkst: String?

    static func weekdayCode(of date: Date) -> String {
        let wd = Calendar.current.component(.weekday, from: date)
        return weekdays.first { $0.weekday == wd }!.code
    }

    func activeDays(start: Date) -> Set<String> {
        days.isEmpty ? [Self.weekdayCode(of: start)] : days
    }

    /// The RRULE body, or nil for no repeat. `until` means "through that day":
    /// a DATE for an all-day series, that day's last second in UTC otherwise.
    func rrule(start: Date, allDay: Bool) -> String? {
        switch freq {
        case .none: return nil
        case .custom: return customRule
        default: break
        }
        var parts = ["FREQ=\(freq.rawValue)"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if freq == .weekly {
            let picked = activeDays(start: start)
            parts.append("BYDAY=" + Self.weekdays.map(\.code).filter(picked.contains).joined(separator: ","))
            if let wkst { parts.append("WKST=\(wkst)") }
        }
        switch ends {
        case .after: parts.append("COUNT=\(max(1, count))")
        case .on:
            // Never before the start's own day: that would be a series that
            // never happens (or, read the other way, one that never ends).
            let until = max(self.until, Calendar.current.startOfDay(for: start))
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            if allDay {
                f.dateFormat = "yyyyMMdd"; f.timeZone = .current
                parts.append("UNTIL=" + f.string(from: until))
            } else {
                let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: until) ?? until
                f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC")
                parts.append("UNTIL=" + f.string(from: endOfDay))
            }
        case .never: break
        }
        return parts.joined(separator: ";")
    }

    /// A series' rule as sheet state, for an event starting at `start`; one the
    /// sheet can't draw (2nd Tuesday, the 15th of a series starting on the 1st)
    /// comes back `.custom` and is saved untouched.
    init(rrule: String?, start: Date) {
        let body = (rrule ?? "").trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "RRULE:", with: "", options: [.caseInsensitive, .anchored])
        guard !body.isEmpty else { return }
        var parts: [String: String] = [:]
        for p in body.split(separator: ";") {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { parts[kv[0].uppercased()] = kv[1] }
        }
        let known: Set = ["FREQ", "INTERVAL", "BYDAY", "COUNT", "UNTIL", "WKST", "BYMONTHDAY", "BYMONTH"]
        let days = parts["BYDAY"].map { $0.split(separator: ",").map { $0.uppercased() } } ?? []
        // BYMONTHDAY/BYMONTH (Graph's absolute patterns read back) only when
        // they are the start's own day and month — what the sheet repeats on.
        let cal = Calendar.current
        // …and only where they mean that: a month day on a monthly/yearly rule,
        // a month on a yearly one. Anywhere else they filter.
        let fr = parts["FREQ"] ?? ""
        let sameDay = parts["BYMONTHDAY"].map { ["MONTHLY", "YEARLY"].contains(fr) && $0 == String(cal.component(.day, from: start)) } ?? true
        let sameMonth = parts["BYMONTH"].map { fr == "YEARLY" && $0 == String(cal.component(.month, from: start)) } ?? true
        guard let f = Freq(rawValue: parts["FREQ"] ?? ""), f != .none, f != .custom,
              Set(parts.keys).isSubset(of: known), sameDay, sameMonth,
              days.isEmpty || (f == .weekly && days.allSatisfy { d in Self.weekdays.contains { $0.code == d } })
        else {
            freq = .custom; customRule = body; return
        }
        freq = f
        interval = Int(parts["INTERVAL"] ?? "") ?? 1
        self.days = Set(days)
        wkst = parts["WKST"]
        if let c = parts["COUNT"].flatMap(Int.init) {
            ends = .after; count = c
        } else if let u = parts["UNTIL"] {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            // A timed UNTIL is a UTC instant; its local day is the one picked.
            fmt.dateFormat = u.count > 8 ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd"
            fmt.timeZone = u.count > 8 ? TimeZone(identifier: "UTC") : .current
            if let d = fmt.date(from: u) { ends = .on; until = d }
        }
    }

    init() {}
}
