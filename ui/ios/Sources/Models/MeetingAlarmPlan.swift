import Foundation

/// One pre-scheduled meeting alarm — what it says and exactly when it fires.
struct MeetingAlarm: Equatable {
    let eventKey: String
    let title: String
    let body: String
    let fireAt: Date
}

/// Which meetings get an alarm. Kept pure (no notification centre, no store, no
/// clock) because these are the rules that decide whether the phone goes off, and
/// getting them wrong is silent both ways — a missed meeting or a 7am false alarm.
/// `MeetingAlarms` owns the scheduling; this owns the decision.
enum MeetingAlarmPlan {
    /// `events` is the agenda read — sorted by start, already excluding
    /// status='cancelled'. Returns at most `limit`, nearest first.
    static func alarms(for events: [CalendarEvent],
                       leadMinutes: Int,
                       now: Date,
                       muted: Set<String>,
                       myEmails: Set<String>,
                       limit: Int) -> [MeetingAlarm] {
        let lead = TimeInterval(leadMinutes * 60)
        var out: [MeetingAlarm] = []
        for event in events {
            guard !event.allDay, let start = event.start, !muted.contains(event.id) else { continue }
            let fireAt = start.addingTimeInterval(-lead)
            // Only ever schedule ahead. A lead time that has already passed isn't an
            // alarm — and firing it anyway would re-nag on every foreground.
            guard fireAt > now.addingTimeInterval(5) else { continue }
            // A meeting you declined shouldn't wake you up.
            if let mine = event.attendees.first(where: { myEmails.contains(($0.email ?? "").lowercased()) }),
               mine.responseStatus == "declined" { continue }

            var body = "Starts in \(leadMinutes) min · \(event.startTimeLabel)"
            if let loc = event.location, !loc.isEmpty, loc.count <= 60 { body += " · \(loc)" }
            out.append(MeetingAlarm(eventKey: event.id, title: event.title, body: body, fireAt: fireAt))
            if out.count >= limit { break }
        }
        return out
    }
}
