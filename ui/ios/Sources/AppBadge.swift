import Foundation
import UserNotifications

/// App-icon unread badge = offline-channel unread (local SQLite) + inbox2-domain
/// (MX) unread. The two halves are known in different places — channels from the
/// engine/SQLite (always available, even on a silent-push wake), domain from
/// `CloudSession` while the app runs — so each is set independently and persisted.
/// A refresh that only knows one half (e.g. a background `channel_sync` wake)
/// keeps the other from its last value rather than zeroing it.
///
/// While the app is closed the server drives the badge instead: every APNs push
/// carries an absolute `aps.badge` (MX unread + this device's last-reported
/// channel unread), and a state change made on another device — mark read, spam,
/// trash — sends a badge-only push for exactly that reason. Whatever the app
/// computes when it next runs wins over the server's number.
@MainActor
enum AppBadge {
    private static let channelKey = "inbox2_badge_channel_unread"
    private static let domainKey = "inbox2_badge_domain_unread"

    /// Offline-channel (Gmail/Outlook/IMAP) unread — from `InboxStore.unreadCount(nil)`.
    static func setChannelUnread(_ n: Int) {
        UserDefaults.standard.set(max(0, n), forKey: channelKey)
        apply()
    }

    /// inbox2-domain (MX) unread — from `CloudSession.refreshUnreadCount()`.
    static func setDomainUnread(_ n: Int) {
        UserDefaults.standard.set(max(0, n), forKey: domainKey)
        apply()
    }

    /// Drop the domain half (sign-out of the MX domain).
    static func clearDomain() { setDomainUnread(0) }

    /// The persisted halves + their sum — the same two numbers `apply()` badges the
    /// icon with. The unified inbox header surfaces `combinedUnread` in-app so the
    /// on-screen `(N)` matches the app-icon badge (channels + MX) from one source.
    static var channelUnread: Int { UserDefaults.standard.integer(forKey: channelKey) }
    static var domainUnread: Int { UserDefaults.standard.integer(forKey: domainKey) }
    static var combinedUnread: Int { channelUnread + domainUnread }

    /// Optimistically nudge a half without a DB/API read. The async write-back +
    /// recompute may not run before the app is backgrounded (e.g. trash a message,
    /// then go to the home screen), leaving the badge stale until the next foreground.
    /// Applying the delta now keeps it correct; the next full refresh reconciles.
    static func adjustChannel(by delta: Int) {
        guard delta != 0 else { return }
        setChannelUnread(UserDefaults.standard.integer(forKey: channelKey) + delta)
    }
    static func adjustDomain(by delta: Int) {
        guard delta != 0 else { return }
        setDomainUnread(UserDefaults.standard.integer(forKey: domainKey) + delta)
    }

    /// Optimistically move the badge for `action` applied to `convos` — the channel
    /// and domain halves are nudged separately (they're persisted separately).
    /// `wasUnread` defaults to the row's unread flag; the reader overrides it to
    /// discount a thread it already marked read in-session.
    static func adjust(_ action: ConversationAction, convos: [Conversation],
                       wasUnread: (Conversation) -> Bool = { $0.unread }) {
        adjustChannel(by: convos.filter { !$0.isDomain }.reduce(0) { $0 + action.badgeDelta(wasUnread: wasUnread($1)) })
        adjustDomain(by: convos.filter { $0.isDomain }.reduce(0) { $0 + action.badgeDelta(wasUnread: wasUnread($1)) })
    }

    private static func apply() {
        let total = UserDefaults.standard.integer(forKey: channelKey)
            + UserDefaults.standard.integer(forKey: domainKey)
        UNUserNotificationCenter.current().setBadgeCount(max(0, total)) { error in
            if let error {
                Log.engine.error("set app badge failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
