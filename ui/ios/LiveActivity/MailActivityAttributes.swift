import ActivityKit
import AppIntents
import Foundation

/// The "Mail" Live Activity (docs/iOS-App.md "Mail Live Activity"): one lock-screen /
/// Dynamic Island card showing the newest unread message with Archive / Read /
/// Trash buttons. Compiled into both the app and the Inbox2Widgets extension.
/// The attributes are empty on purpose — everything lives in the content state so
/// one card can advance from message to message, and so Rails can push-to-start it
/// with `"attributes": {}`.
struct MailActivityAttributes: ActivityAttributes {
    /// Field names are the wire contract with Rails
    /// (`MobilePushSender.live_activity_state` + the delivery job) — keep in sync.
    struct ContentState: Codable, Hashable {
        var conversationKey: String
        /// Channel account key (`accountKey` in the store); empty for MX mail.
        var accountKey: String
        /// MX org key (`org_…`); empty for channel mail.
        var orgId: String
        var sender: String
        var subject: String
        var snippet: String
        /// Total unread (channel + MX) — the "+N" pill; same number as the app badge.
        var unread: Int
        /// Epoch seconds — ActivityKit push content-state can't carry a `Date`.
        var receivedAt: Double

        var isDomain: Bool { !orgId.isEmpty }
    }
}

/// One card button. `LiveActivityIntent` runs in the APP's process (iOS launches
/// it in the background if needed) — so the widget never touches the engine; the
/// app-side body reuses the notification-action queue and then advances the card.
struct MailActivityActionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mail action"
    /// No UI, no app foregrounding — the whole point.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Action") var verb: String
    @Parameter(title: "Conversation") var conversationKey: String
    @Parameter(title: "Account") var accountKey: String
    @Parameter(title: "Org") var orgId: String

    init() {}
    init(verb: String, state: MailActivityAttributes.ContentState) {
        self.verb = verb
        self.conversationKey = state.conversationKey
        self.accountKey = state.accountKey
        self.orgId = state.orgId
    }

    func perform() async throws -> some AppIntents.IntentResult {
        #if !INBOX2_WIDGET
        await MailActivityManager.shared.perform(verb: verb, conversationKey: conversationKey,
                                                 accountKey: accountKey, orgId: orgId)
        #endif
        return .result()
    }
}
