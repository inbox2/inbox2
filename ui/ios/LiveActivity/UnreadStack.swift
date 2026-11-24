import AppIntents
import Foundation
import WidgetKit

/// The "Unread" home-screen widget: a stack of unread mail you work through with
/// Read / Archive / In 3 h / Trash and the "Move to" quadrants. The app writes the
/// top of the unread inbox (channels + MX) into the App Group; the widget only
/// renders it. Compiled into both the app and Inbox2Widgets.
struct UnreadStackItem: Codable, Hashable, Identifiable {
    var id: String          // conversation key
    /// Channel account key; empty for MX mail.
    var accountKey: String
    /// MX org key; empty for channel mail.
    var orgId: String
    var sender: String
    var initials: String
    var seed: Int
    var subject: String
    var snippet: String
    var receivedAt: Double
    /// Quadrants are channel-only, snooze is MX-only (Conversation.supportsTriage/Snooze).
    var canMove: Bool
    var canSnooze: Bool
}

struct UnreadStackSnapshot: Codable {
    var items: [UnreadStackItem] = []
    var unread: Int = 0
}

enum UnreadStack {
    static let kind = "UnreadStack"
    static let snoozeVerb = "snooze_3h"
    private static let key = "inbox2_unread_stack"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: "group.com.inbox2.ios") }

    static func load() -> UnreadStackSnapshot {
        guard let data = defaults?.data(forKey: key),
              let s = try? JSONDecoder().decode(UnreadStackSnapshot.self, from: data) else { return .init() }
        return s
    }

    static func save(_ s: UnreadStackSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        if defaults?.data(forKey: key) == data { return }   // no reload when nothing changed
        defaults?.set(data, forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    /// MX mail off the stack (signed out of inbox2); `channelUnread` is the new total.
    static func dropDomain(channelUnread: Int) {
        var s = load()
        s.items = s.items.filter { $0.orgId.isEmpty }
        s.unread = max(channelUnread, s.items.count)
        save(s)
    }

    /// Take a handled card off the top right away; the action lands after.
    static func drop(_ id: String) {
        var s = load()
        guard let i = s.items.firstIndex(where: { $0.id == id }) else { return }
        s.items.remove(at: i)
        s.unread = max(s.items.count, s.unread - 1)
        save(s)
    }
}

/// One widget button. A `LiveActivityIntent` runs in the APP's process (launched in
/// the background if needed), like `MailActivityActionIntent`, so the widget never
/// touches the engine. `verb` is an engine verb (`archive`, `set_quadrant:LATER`, …)
/// or `UnreadStack.snoozeVerb`.
struct UnreadStackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Handle unread mail"
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false

    @Parameter(title: "Action") var verb: String
    @Parameter(title: "Conversation") var conversationKey: String
    @Parameter(title: "Account") var accountKey: String
    @Parameter(title: "Org") var orgId: String

    init() {}
    init(verb: String, item: UnreadStackItem) {
        self.verb = verb
        conversationKey = item.id
        accountKey = item.accountKey
        orgId = item.orgId
    }

    func perform() async throws -> some AppIntents.IntentResult {
        #if !INBOX2_WIDGET
        await UnreadStackFeed.shared.perform(verb: verb, conversationKey: conversationKey,
                                             accountKey: accountKey, orgId: orgId)
        #endif
        return .result()
    }
}
