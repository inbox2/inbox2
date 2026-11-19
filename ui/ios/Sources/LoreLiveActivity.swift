import ActivityKit
import Foundation

/// The app side of Lore's "Next up · Done" card (docs/Live-Activity.md "Lore"). The
/// app decides what is next (`LoreToday.nextUp`); only a foreground app may start a
/// card, so a background Done can update it or end it, never start one.
@MainActor
final class LoreActivityManager {
    static let shared = LoreActivityManager()
    private static let enabledKey = "lore_live_activity_enabled"

    /// Off by default: a card on the Lock Screen is something the person asks for.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var activities: [Activity<LoreActivityAttributes>] { Activity<LoreActivityAttributes>.activities }

    private func state(_ c: Conversation, more: Int) -> LoreActivityAttributes.ContentState {
        let cleaned = LoreText.clean(c.subject)
        let bucket = LoreBucket.forLabel(c.triageLabel) ?? .work
        return .init(conversationKey: c.id, accountKey: c.isDomain ? nil : c.accountKey,
                     orgId: c.isDomain ? c.accountKey : nil,
                     title: cleaned.isEmpty ? (c.subject.isEmpty ? "(no subject)" : c.subject) : cleaned,
                     sender: c.sender, tag: bucket.tag,
                     verb: c.isMemberDone ? ConversationAction.loreDone.verb : ConversationAction.archive.verb,
                     more: more)
    }

    /// Bring the card in line with Today. Called after every Lore reload and when the
    /// switch changes; starting a card needs the app in front.
    func sync(_ today: LoreToday) {
        let next = today.nextUp
        guard isEnabled, let next else {
            activities.forEach { activity in Task { await activity.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        let content = state(next, more: max(today.open - 1, 0))
        if let current = activities.first {
            guard current.content.state != content else { return }
            Task { await current.update(.init(state: content, staleDate: nil)) }
        } else if AppActivity.isForeground, ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                _ = try Activity.request(attributes: LoreActivityAttributes(startedAt: Date()),
                                         content: .init(state: content, staleDate: nil), pushType: nil)
            } catch {
                Log.ui.error("lore live activity failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The card's Done button: tick the item off through the notification-action queue
    /// (durable, waits for a cold-started engine), then move to what is next.
    func done(conversationKey: String, accountKey: String?, orgId: String?, verb: String) async {
        await NotificationManager.shared.perform(.init(verb: verb, conversationKey: conversationKey,
                                                       accountKey: accountKey, orgId: orgId))
        guard let engine = PushRegistrar.engine, let cloud = PushRegistrar.cloud else { return }
        let loader = InboxLoader()
        await loader.reload(LoreView.scope, engine: engine, cloud: cloud)
        sync(LoreToday.build(loader.conversations.filter { $0.id != conversationKey }))
    }
}
