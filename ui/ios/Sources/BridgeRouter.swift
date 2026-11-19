import Foundation

/// Routes a Bridge voice command's DRAFT result onto the screen. The voice agent never
/// sends or saves — when it produces a draft, it sets one of these and `RootTabs`
/// presents the matching sheet (Compose / New Event) above whatever tab is showing, so
/// the user reviews and commits with Send / Add.
@MainActor
final class BridgeRouter: ObservableObject {
    /// Set to open a prefilled email compose sheet (a drafted reply).
    @Published var pendingCompose: ComposeDraft?
    /// Set to open a prefilled new-event sheet (a drafted meeting).
    @Published var pendingEvent: EventDraftSeed?
}

/// Seed values for a drafted calendar event surfaced by the Bridge. Attendees are
/// resolved email addresses (with any unresolved names left as-is for the user to fix).
struct EventDraftSeed: Identifiable {
    let id = UUID()
    var title: String
    var start: Date
    var end: Date
    var location: String
    var attendees: [String]
}
