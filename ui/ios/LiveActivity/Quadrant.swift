import Foundation

// Shared with Inbox2Widgets (the Unread stack's "Move to" chips).
/// Eisenhower triage quadrant — matches the desktop `lib/priority.js` keys. Carries
/// its own menu label + glyph so the "Move to" submenus are data-driven.
enum Quadrant: String, CaseIterable, Identifiable {
    case doFirst = "DO_FIRST"
    case schedule = "SCHEDULE"
    case delegate = "DELEGATE"
    case later = "LATER"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .doFirst: return "Priority"
        case .schedule: return "Schedule"
        case .delegate: return "Delegate"
        case .later: return "Later"
        }
    }
    /// Glyphs match the desktop Eisenhower quadrants (web lib/priority.js) and
    /// MailFolder's triage views, so the same quadrant never wears two icons.
    var systemImage: String {
        switch self {
        case .doFirst: return "flame.fill"
        case .schedule: return "calendar.badge.clock"
        case .delegate: return "person.badge.plus"
        case .later: return "clock"
        }
    }
}
