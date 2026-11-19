import SwiftUI

/// The four Outlook-style mark-as-read modes, mirroring the desktop
/// `MARK_READ_MODES` (lib/markReadPref.js). Single source for the values + labels.
enum MarkReadMode: String, CaseIterable, Identifiable {
    case immediate       // mark read as soon as the message is opened
    case delay           // mark read after it's been displayed N seconds (default)
    case selectionChange // mark read when you move on to another message
    case never           // manual only

    var id: String { rawValue }
    var title: String {
        switch self {
        case .immediate: return "When opened"
        case .delay: return "After a delay"
        case .selectionChange: return "When I leave it"
        case .never: return "Manually only"
        }
    }
    var detail: String {
        switch self {
        case .immediate: return "Marks it read as soon as you open it."
        case .delay: return "Marks it read after a few seconds on screen."
        case .selectionChange: return "Marks it read when you go back or open another."
        case .never: return "You mark mail read yourself."
        }
    }
}

/// Persists the user's mark-as-read preference (mode + dwell seconds), mirroring
/// the desktop markReadPref. Injected via the environment; the reader reads it,
/// Settings edits it.
@MainActor
final class MarkReadManager: ObservableObject {
    @Published var mode: MarkReadMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published var delaySeconds: Int {
        didSet { UserDefaults.standard.set(delaySeconds, forKey: Self.delayKey) }
    }

    private static let modeKey = "inbox2_mark_read_mode"
    private static let delayKey = "inbox2_mark_read_delay"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeKey)
        // Default to marking read the moment a message is opened, so a quick
        // open/back still counts (the delay mode cancels its dwell on a fast exit).
        mode = MarkReadMode(rawValue: raw ?? "") ?? .immediate
        let d = UserDefaults.standard.integer(forKey: Self.delayKey)
        delaySeconds = d > 0 ? d : 5
    }
}
