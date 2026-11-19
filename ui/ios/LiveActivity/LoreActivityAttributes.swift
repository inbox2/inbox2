import ActivityKit
import AppIntents
import Foundation

/// Lore's "Next up · Done" Live Activity (docs/Live-Activity.md "Lore"): the top item
/// of Today, with a Done button that ticks it off without opening the app. Opt-in,
/// started from the app in the foreground only. Compiled into both the app and
/// Inbox2Widgets.
struct LoreActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var conversationKey: String
        /// Set for channel mail; MX mail goes by `orgId` (the same routing as the mail card).
        var accountKey: String?
        var orgId: String?
        var title: String
        var sender: String
        var tag: String
        /// `archive`, or `lore_done` for a personal bucket on a shared domain.
        var verb: String
        /// Items left after this one, for the "+N" pill.
        var more: Int
    }

    var startedAt: Date
}

/// The card's Done button. Runs in the APP's process (a `LiveActivityIntent`, launched in
/// the background if needed), like `ZoneDoneIntent` and `MailActivityActionIntent`.
struct LoreDoneIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Lore item done"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Conversation") var conversationKey: String
    @Parameter(title: "Account") var accountKey: String
    @Parameter(title: "Org") var orgId: String
    @Parameter(title: "Action") var verb: String

    init() {}
    init(state: LoreActivityAttributes.ContentState) {
        conversationKey = state.conversationKey
        accountKey = state.accountKey ?? ""
        orgId = state.orgId ?? ""
        verb = state.verb
    }

    func perform() async throws -> some AppIntents.IntentResult {
        #if !INBOX2_WIDGET
        await LoreActivityManager.shared.done(conversationKey: conversationKey,
                                               accountKey: accountKey.isEmpty ? nil : accountKey,
                                               orgId: orgId.isEmpty ? nil : orgId, verb: verb)
        #endif
        return .result()
    }
}
