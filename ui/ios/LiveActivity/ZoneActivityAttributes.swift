import ActivityKit
import AppIntents
import Foundation

/// The "You're in the zone" Live Activity (docs/iOS-App.md "Zones"): a lock-screen /
/// Dynamic Island countdown for the active notify-zone. Started by the app in the
/// foreground only (no push-to-start — zones are local to this user), ended on
/// Done (in-app card or the card's own `ZoneDoneIntent` button) or when the zone runs out. Compiled into both the app and Inbox2Widgets.
/// Everything is fixed for the zone's life, so it all lives in the attributes.
struct ZoneActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {}

    var zoneId: String
    var name: String
    var note: String
    var category: String
    /// Palette key (blue/amber/…) — the widget maps it to a literal colour.
    var colorKey: String
    var start: Date
    var end: Date
}

/// The card's Done button. Like `MailActivityActionIntent`, a `LiveActivityIntent`
/// runs in the APP's process (launched in the background if needed), so it writes
/// the same dismissed set the in-app card uses and ends the activity there.
struct ZoneDoneIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Zone done"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    /// The occurrence id — each day of a repeating zone is dismissed on its own.
    @Parameter(title: "Zone") var zoneId: String

    init() {}
    init(zoneId: String) { self.zoneId = zoneId }

    func perform() async throws -> some AppIntents.IntentResult {
        #if !INBOX2_WIDGET
        // Await the server POST so the other devices hear about it before we're suspended.
        await MainActor.run { ZoneStore.shared.dismiss(id: zoneId) }.value
        #endif
        return .result()
    }
}
