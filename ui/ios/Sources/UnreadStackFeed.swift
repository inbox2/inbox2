import Foundation

/// App side of the Unread widget (LiveActivity/UnreadStack.swift): writes the top of
/// the unread inbox into the App Group and applies the widget's buttons.
@MainActor
final class UnreadStackFeed {
    static let shared = UnreadStackFeed()

    /// Cards kept in the snapshot, so the next one is there the moment one is handled.
    private static let depth = 6
    /// A handled thread stays out of the stack this long, so a sync that lands before
    /// the write-back can't put it back on top (the same window as the inbox guard).
    private static let handledWindow: TimeInterval = 180
    private var handled: [String: Date] = [:]
    private var orgUnread: [String: Int] = [:]

    func refresh() async {
        guard let engine = PushRegistrar.engine else { return }
        let now = Date()
        handled = handled.filter { now.timeIntervalSince($0.value) < Self.handledWindow }
        var convos = await engine.store.read {
            Array($0.conversations(accountKey: nil, folder: .inbox, filter: .unread, query: "").prefix(Self.depth * 2))
        }
        // The app badge counts the current org only; the stack spans every org.
        var unread = AppBadge.channelUnread
        if let cloud = PushRegistrar.cloud, cloud.isSignedIn {
            for org in cloud.orgs {   // every org, like the unified inbox (InboxLoader.loadOrgPools)
                convos += await cloud.conversations(folder: .inbox, view: "Unread", query: "", orgId: org.id)
                    .prefix(Self.depth * 2)
                // A failed count keeps that org's last one rather than dropping to zero.
                if let n = await cloud.unreadCount(orgId: org.id) { orgUnread[org.id] = n }
                unread += orgUnread[org.id] ?? 0
            }
        }
        // Signed out while this ran: the cleared snapshot must not get MX cards back.
        let signedIn = PushRegistrar.cloud?.isSignedIn ?? false
        if !signedIn { convos = convos.filter { !AccountKey.isDomain($0.accountKey) } }
        let date = { (c: Conversation) in RelativeTime.parse(c.updatedAt) ?? .distantPast }
        let items = convos
            .filter { handled[$0.id] == nil }
            .sorted { date($0) > date($1) }
            .prefix(Self.depth)
            .map { c -> UnreadStackItem in
                let isDomain = AccountKey.isDomain(c.accountKey)
                return .init(id: c.id,
                             accountKey: isDomain ? "" : c.accountKey,
                             orgId: isDomain ? c.accountKey : "",
                             sender: c.sender.isEmpty ? c.email : c.sender,
                             initials: c.initials, seed: c.seed,
                             subject: c.subject.isEmpty ? "(No subject)" : c.subject,
                             snippet: c.snippet,
                             receivedAt: date(c).timeIntervalSince1970,
                             canMove: c.supportsTriage, canSnooze: c.supportsSnooze)
            }
        UnreadStack.save(.init(items: Array(items), unread: max(signedIn ? unread : AppBadge.channelUnread, items.count)))
    }

    /// Widget button body. Card first, action second, like the Live Activity: the
    /// stack moves on at once, then the action goes through the durable
    /// notification-action queue (snooze straight to the API, MX only).
    func perform(verb: String, conversationKey: String, accountKey: String, orgId: String) async {
        guard !conversationKey.isEmpty else { return }
        handled[conversationKey] = Date()
        UnreadStack.drop(conversationKey)
        let acct = accountKey.isEmpty ? nil : accountKey
        let org = orgId.isEmpty ? nil : orgId
        if verb == UnreadStack.snoozeVerb {
            for _ in 0..<50 where PushRegistrar.cloud == nil || PushRegistrar.cloud?.state == .loading {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let ok = await PushRegistrar.cloud?.snooze(conversationId: conversationKey,
                                                       until: ReplyComposer.snoozeDate(hoursFromNow: 3), orgId: org) ?? false
            // ponytail: no retry queue for snooze; a failed one puts the card back instead.
            if !ok { handled[conversationKey] = nil }
        } else {
            await NotificationManager.shared.perform(.init(verb: verb, conversationKey: conversationKey,
                                                           accountKey: acct, orgId: org))
            // "Move to" keeps the thread in the inbox; it counts as handled, so read it too.
            if verb.hasPrefix("set_quadrant:") {
                await NotificationManager.shared.perform(.init(verb: ConversationAction.markRead.verb,
                                                               conversationKey: conversationKey,
                                                               accountKey: acct, orgId: org))
            }
        }
        await refresh()
    }
}
