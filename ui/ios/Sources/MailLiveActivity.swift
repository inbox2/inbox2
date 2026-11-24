import ActivityKit
import Foundation

/// Drives the "Mail" Live Activity (LiveActivity/MailActivityAttributes.swift): the
/// lock-screen card with the newest unread message + Archive / Read / Trash.
///
/// - `refresh()` recomputes the newest unread across channels (SQLite) and MX (API),
///   updates the running card to it, ends the card when nothing is unread, and
///   starts one when the app is in the foreground. iOS forbids STARTING from the
///   background, so for mail that lands while the phone is locked the start is an
///   APNs push-to-start (docs/Cloud-Push.md "Live Activity"): Rails sends it
///   itself for MX mail (it has the content); for channel mail the woken app asks
///   Rails to send it after the sync, with the content, and only when there is
///   new unread mail and no card — Rails can't tell new mail from the echo of our
///   own write-back, so it never starts a card on its own for channels.
/// - Tokens: the long-lived push-to-start token and each running card's update
///   token go to Rails via PushRegistrar so it knows whether to `start` or `update`.
/// - `perform(...)` is the App Intent body: apply the action through the same queue
///   the notification buttons use, then advance the card.
@MainActor
final class MailActivityManager {
    static let shared = MailActivityManager()
    private var observing = false
    private var tracked = Set<String>()
    /// Last start we asked Rails for (conversation, when) — one ask per message.
    private var lastStartRequest: (key: String, at: Date)?

    /// Diagnostics that survive without a Mac-side log stream: appended to
    /// Documents/inbox2/live-activity.log (pull with `devicectl device copy from`,
    /// see docs/iOS-Device.md) as well as the unified log.
    func note(_ message: String) {
        Log.ui.info("live activity: \(message, privacy: .public)")
        DiagLog.note("live-activity.log", message)
    }

    /// Once per process (Inbox2App). Also adopts cards that already exist — e.g. one
    /// Rails push-started while the process was dead.
    func startObserving() {
        guard !observing else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { note("activities disabled in Settings"); return }
        observing = true
        note("observing (foreground=\(AppActivity.isForeground))")
        Task {
            for await token in Activity<MailActivityAttributes>.pushToStartTokenUpdates {
                note("push-to-start token \(Self.hex(token).prefix(8))…")
                await PushRegistrar.reportLiveActivity(startToken: Self.hex(token))
            }
        }
        Task {
            for await activity in Activity<MailActivityAttributes>.activityUpdates {
                note("activity appeared \(activity.id) for \(activity.content.state.conversationKey)")
                self.track(activity)
                await self.refresh()
            }
        }
        Activity<MailActivityAttributes>.activities.forEach(track)
        // No card on this device → make sure Rails doesn't think there is one (a
        // reinstall / swipe-away while the process was dead was never reported), else
        // it keeps updating a dead token instead of starting. Checked after a few
        // seconds: at process start ActivityKit may not have listed the cards yet.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, Activity<MailActivityAttributes>.activities.isEmpty else { return }
            self.note("no running card; clearing server activity token")
            await PushRegistrar.reportLiveActivity(activityToken: .some(nil))
        }
    }

    private func track(_ activity: Activity<MailActivityAttributes>) {
        guard tracked.insert(activity.id).inserted else { return }
        Task {
            for await token in activity.pushTokenUpdates {
                note("card \(activity.id) token \(Self.hex(token).prefix(8))…")
                await PushRegistrar.reportLiveActivity(activityToken: Self.hex(token))
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                note("card \(activity.id) \(state == .ended ? "ended" : "dismissed")")
                self.tracked.remove(activity.id)
                // Only forget the token if no other card took over.
                if Activity<MailActivityAttributes>.activities.isEmpty {
                    await PushRegistrar.reportLiveActivity(activityToken: .some(nil))
                }
            }
        }
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Bring the card in line with the inbox: newest unread → update (or start, when
    /// foreground); nothing unread → end.
    /// `excluding` drops one conversation from the lookup — the one a card button just
    /// acted on, so the card moves on before the action has been applied.
    func refresh(excluding: String? = nil) async {
        // The Unread widget follows the same inbox changes as the card.
        await UnreadStackFeed.shared.refresh()
        guard observing, let engine = PushRegistrar.engine else { return }
        let state = await newestUnread(engine: engine, cloud: PushRegistrar.cloud, excluding: excluding)
        let activities = Activity<MailActivityAttributes>.activities
        guard let state else {
            for a in activities {
                note("refresh: no unread, ending \(a.id)")
                await a.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        note("refresh: newest unread \(state.conversationKey) '\(state.subject)' cards=\(activities.count)")
        let content = ActivityContent(state: state, staleDate: nil)
        if let current = activities.first {
            await current.update(content)
            // A push-to-start racing a local start can leave two; keep one.
            for extra in activities.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        } else if AppActivity.isForeground {
            // A start we asked Rails for seconds ago is about to land — don't race it
            // with a local one (two cards, one immediately ended).
            if let r = lastStartRequest, r.key == state.conversationKey, Date().timeIntervalSince(r.at) < 10 {
                note("start already requested from Rails; waiting")
                return
            }
            do {
                track(try Activity.request(attributes: MailActivityAttributes(), content: content, pushType: .token))
                note("started card locally for \(state.conversationKey)")
            } catch {
                note("local start failed: \(error)")
            }
        } else if lastStartRequest.map({ $0.key != state.conversationKey || Date().timeIntervalSince($0.at) > 300 }) ?? true {
            // iOS won't let a background process start a card, so ask Rails to
            // push-start one with this content (docs/Cloud-Push.md "Live Activity").
            // Once per message: the card's own token report tells Rails it's up.
            lastStartRequest = (state.conversationKey, Date())
            note("asking Rails to push-start a card for \(state.conversationKey)")
            await PushRegistrar.requestLiveActivityStart(state)
        }
    }

    /// Newest unread inbox thread across channels (local store) and MX (current org,
    /// when signed in). nil when the inbox has no unread.
    private func newestUnread(engine: EngineModel, cloud: CloudSession?, excluding: String? = nil) async -> MailActivityAttributes.ContentState? {
        var candidates = await engine.store.read {
            Array($0.conversations(accountKey: nil, folder: .inbox, filter: .unread, query: "")
                .lazy.filter { $0.id != excluding }.prefix(1))
        }
        if let cloud, cloud.isSignedIn,
           let mx = await cloud.conversations(folder: .inbox, view: "Unread", query: "").first(where: { $0.id != excluding }) {
            candidates.append(mx)
        }
        guard let newest = candidates.max(by: {
            (RelativeTime.parse($0.updatedAt) ?? .distantPast) < (RelativeTime.parse($1.updatedAt) ?? .distantPast)
        }) else { return nil }
        let isDomain = AccountKey.isDomain(newest.accountKey)
        let from = MailAddress.parse(newest.fromAddress)
        return .init(conversationKey: newest.id,
                     accountKey: isDomain ? "" : newest.accountKey,
                     orgId: isDomain ? newest.accountKey : "",
                     sender: from.name.isEmpty ? from.email : from.name,
                     subject: newest.subject.isEmpty ? "(No subject)" : newest.subject,
                     snippet: newest.snippet,
                     unread: max(AppBadge.combinedUnread, 1),
                     receivedAt: (RelativeTime.parse(newest.updatedAt) ?? Date()).timeIntervalSince1970)
    }

    /// App Intent body (a card button). Same durable path as a notification button;
    /// `drainPendingActions` waits for the engine on a cold background launch.
    func perform(verb: String, conversationKey: String, accountKey: String, orgId: String) async {
        guard !conversationKey.isEmpty else { return }
        startObserving()   // a background-launched process hasn't run the app's launch task
        note("button \(verb) on \(conversationKey)")
        // Card first, action second: move to the next unread (or end) right away, then
        // apply the action — it's durable in the engine / one API call, and the
        // trailing refresh reconciles whatever the action changed.
        await refresh(excluding: conversationKey)
        await NotificationManager.shared.perform(.init(verb: verb, conversationKey: conversationKey,
                                                       accountKey: accountKey.isEmpty ? nil : accountKey,
                                                       orgId: orgId.isEmpty ? nil : orgId))
        await refresh()
    }
}
