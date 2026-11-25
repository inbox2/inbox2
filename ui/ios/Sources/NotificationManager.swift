import CryptoKit
import Foundation
import UIKit
import Intents
import UserNotifications

/// Local notifications for new mail. Posts a banner from the engine's
/// `new-message` event while the app is running (foreground banners via the
/// delegate). Real push when the app is closed needs APNs (deferred — a Rails-side
/// sender + cert). Gated by the Settings toggles (persisted in UserDefaults).
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    static let newMailKey = "inbox2_notify_new_mail"
    static let soundKey = "inbox2_notify_sound"

    /// Category on every new-mail notification (local + the Rails APNs alert, which
    /// sets `aps.category` to the same string) so both carry the action buttons.
    static let mailCategory = "MAIL"
    /// Action identifiers = the engine/cloud verbs, so the handler passes them
    /// straight through. Mirrors the desktop card's Read/Archive/Delete row.
    private static let mailActions: [(action: ConversationAction, title: String)] =
        [(.markRead, "Mark as read"), (.archive, "Archive"), (.trash, "Trash")]
    /// Sign-in mail (the core's `otp` detection locally; Rails sets the same
    /// categories on the MX push): the code or link is the point of the card, so
    /// the first button uses it and deletes the thread. Archive/Delete are the
    /// mail verbs, handled exactly like the MAIL buttons.
    static let otpCodeCategory = "OTP_CODE"
    static let otpLinkCategory = "OTP_LINK"
    private static let copyCodeAction = "otp_copy"
    private static let openLinkAction = "otp_open"
    private static let pendingActionsKey = "inbox2_pending_notification_actions"

    /// A notification-button action waiting to be applied. Persisted so an action
    /// taken while the app process is not up (or the engine is still booting) is
    /// applied on the next launch instead of being lost.
    struct PendingAction: Codable, Equatable {
        let verb: String
        let conversationKey: String
        /// Channel account (`accountKey` from the engine payload); nil for MX mail.
        let accountKey: String?
        /// MX org (`organization_id` from the push); nil for channel mail.
        let orgId: String?
    }

    /// Conversation key of a tapped notification. RootTabs jumps to the Inbox tab
    /// and the inbox consumes the key (pops to root, pushes the thread). Held here
    /// (not delivered directly) so a cold-launch tap survives until the views exist.
    @Published var pendingConversationKey: String?

    /// Calendar event key of a tapped meeting alarm (MeetingAlarms). Held for the
    /// same reason as above — a cold-launch tap has to survive until RootTabs exists,
    /// which then hands it to `ChromeModel.pendingCalendarEventKey`.
    @Published var pendingEventKey: String?

    private var newMailEnabled: Bool { UserDefaults.standard.object(forKey: Self.newMailKey) as? Bool ?? true }
    private var soundEnabled: Bool { UserDefaults.standard.object(forKey: Self.soundKey) as? Bool ?? true }

    /// Ask once for permission and register as the foreground presentation delegate.
    func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = self
        let actions = Self.mailActions.map {
            UNNotificationAction(identifier: $0.action.verb, title: $0.title,
                                 options: $0.action == .trash ? [.destructive] : [])
        }
        let archive = UNNotificationAction(identifier: ConversationAction.archive.verb, title: "Archive")
        let delete = UNNotificationAction(identifier: ConversationAction.trash.verb, title: "Delete", options: [.destructive])
        // Copy needs no foreground: a pasteboard write from a background action is allowed.
        let copy = UNNotificationAction(identifier: Self.copyCodeAction, title: "Copy & delete")
        let open = UNNotificationAction(identifier: Self.openLinkAction, title: "Open & delete", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: Self.mailCategory, actions: actions, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.otpCodeCategory, actions: [copy, archive, delete], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.otpLinkCategory, actions: [open, archive, delete], intentIdentifiers: []),
        ])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { Log.engine.error("notification auth error: \(String(describing: error), privacy: .public)") }
            else { Log.engine.info("notification auth granted=\(granted)") }
        }
    }

    /// Post a local notification from a `new-message` payload, honoring the
    /// Settings toggles. Keys mirror the engine's NewMessageNotification.
    func postNewMessage(payloadJSON: String) {
        guard newMailEnabled else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any] else { return }
        let from = MailAddress.parse(obj["from_address"] as? String ?? "")
        let sender = from.name
        let subject = (obj["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "(No subject)"
        let snippet = (obj["snippet"] as? String) ?? ""

        let content = UNMutableNotificationContent()
        content.title = sender.isEmpty ? "New mail" : sender
        content.subtitle = subject
        content.body = snippet
        if soundEnabled { content.sound = .default }
        content.categoryIdentifier = Self.mailCategory

        let id = (obj["key"] as? String) ?? UUID().uuidString
        var userInfo: [String: Any] = [:]
        if let key = obj["key"] as? String {
            userInfo = ["conversationKey": key, "accountKey": obj["accountKey"] as? String ?? ""]
            // Same grouping key a visible MX push carries (aps thread-id), so
            // removeDelivered(conversationKeys:) matches both kinds uniformly.
            content.threadIdentifier = key
        }

        // Large icon, as on the desktop card: the sender's face (Meta DMs), else
        // the sign-in link's host, else the sender's domain — never a freemail
        // one (it names the provider, not the sender).
        let senderHost = from.email.split(separator: "@").last.map { String($0).lowercased() }
        var iconHost = senderHost.flatMap { Self.freemail.contains($0) ? nil : $0 }
        // Sign-in mail: the code / link host leads the card; the sender moves to
        // the subtitle. userInfo uses the MX push's flat keys so one handler serves both.
        let otp = obj["otp"] as? [String: Any]
        if let code = otp?["code"] as? String {
            content.categoryIdentifier = Self.otpCodeCategory
            content.title = "Code \(code)"
            content.subtitle = sender.isEmpty ? "New mail" : sender
            content.body = subject
            userInfo["otp_code"] = code
        } else if let link = otp?["link"] as? String, let host = otp?["host"] as? String {
            content.categoryIdentifier = Self.otpLinkCategory
            content.title = "Sign-in link · \(host)"
            content.subtitle = sender.isEmpty ? "New mail" : sender
            content.body = subject
            userInfo["otp_link"] = link
            userInfo["otp_host"] = host
            iconHost = host
        }
        content.userInfo = userInfo

        Task {
            let iconURL = (obj["from_avatar"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? iconHost.map { "https://\($0)/favicon.ico" }
            var posted: UNNotificationContent = content
            if let iconURL, let png = await Self.iconPNG(url: iconURL) {
                posted = await Self.withSenderIcon(content, png: png, handle: from.email.isEmpty ? id : from.email)
            }
            let req = UNNotificationRequest(identifier: id, content: posted, trigger: nil)
            do { try await UNUserNotificationCenter.current().add(req) }
            catch { Log.engine.error("post notification failed: \(String(describing: error), privacy: .public)") }
        }
        Log.engine.info("posted new-mail notification from \(sender.isEmpty ? "unknown" : sender)")
        // The lock-screen card shows the newest unread — advance it to this one.
        Task { await MailActivityManager.shared.refresh() }
    }

    /// A favicon from these says "Google", not who wrote to you (web lib/otp.js FREEMAIL).
    private static let freemail: Set<String> = ["gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com", "icloud.com", "me.com"]

    /// The sender's icon (favicon or avatar) as PNG, fetched only through the Rails
    /// image proxy (never from the site itself). Time-boxed at 1.5s; nil on any
    /// failure and the card posts without it. Re-encoded because .ico won't do.
    private static func iconPNG(url: String) async -> Data? {
        let apiKey = Keychain.get(PrivacyStore.apiKeyAccount)
        let dataURI: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await ImageProxy.fetchDataURI(url, apiKey: apiKey) }
            group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let b64 = dataURI?.split(separator: ",", maxSplits: 1).last,
              let data = Data(base64Encoded: String(b64)),
              let png = UIImage(data: data)?.pngData() else { return nil }
        return png
    }

    /// The icon as the small inline image on the card's left, like the desktop card:
    /// a communication notification (INSendMessageIntent sender). An attachment would
    /// sit as a thumbnail and blow up to full width on expand. The sender's display
    /// name is the card title, so it carries `content.title` (also "Code 123456").
    /// Without the communication entitlement `updating(from:)` throws → no icon.
    private static func withSenderIcon(_ content: UNMutableNotificationContent, png: Data, handle: String) async -> UNNotificationContent {
        let image = INImage(imageData: png)
        let sender = INPerson(personHandle: INPersonHandle(value: handle, type: .emailAddress),
                              nameComponents: nil, displayName: content.title, image: image,
                              contactIdentifier: nil, customIdentifier: handle)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
                                         content: content.body, speakableGroupName: nil,
                                         conversationIdentifier: content.threadIdentifier.isEmpty ? nil : content.threadIdentifier,
                                         serviceName: nil, sender: sender, attachments: nil)
        intent.setImage(image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        do { return try content.updating(from: intent) }
        catch {
            Log.engine.info("sender icon skipped: \(String(describing: error), privacy: .public)")
            return content
        }
    }

    /// Conversation key a delivered notification belongs to — locally posted
    /// mail carries `conversationKey` in userInfo + threadIdentifier; a visible
    /// MX push (Rails) carries `conversation_id` in userInfo and the same
    /// threadIdentifier (aps thread-id) and uses the message key as identifier.
    private nonisolated func conversationKey(of note: UNNotification) -> String? {
        let info = note.request.content.userInfo
        if let key = info["conversationKey"] as? String { return key }
        if let key = info["conversation_id"] as? String { return key }
        let thread = note.request.content.threadIdentifier
        return thread.isEmpty ? nil : thread
    }

    /// Cross-device tag for a local-channel thread: the first 16 bytes of
    /// sha256("inbox2-clear:" + id), hex. Same as `notification_tag` in the Rust
    /// core (shared vector: "me@example.com:18c2f0a1b3d4e5f6" → c00deed116dc085094d2bd171051f9ac).
    nonisolated static func notificationTag(_ id: String) -> String {
        SHA256.hash(data: Data("inbox2-clear:\(id)".utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Clear any delivered notification(s) for these conversations from the
    /// lockscreen / Notification Center. Drives both paths: a Rails-routed
    /// `remove_notification` push (MX mail dealt with elsewhere) and the
    /// post-sync reconciliation for local channels. No-op for keys with nothing
    /// on screen.
    func removeDelivered(conversationKeys keys: [String]) {
        let wanted = Set(keys)
        guard !wanted.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { [weak self] delivered in
            guard let self else { return }
            let ids = delivered
                .filter { self.conversationKey(of: $0).map(wanted.contains) ?? false }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
            Log.engine.info("cleared \(ids.count) delivered notification(s) for \(wanted.count) conversation(s)")
        }
    }

    /// Distinct conversation keys with a notification currently on screen — the
    /// input to channel reconciliation (the caller drops the ones whose
    /// conversation no longer warrants a banner).
    func deliveredConversationKeys() async -> [String] {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        return Array(Set(delivered.compactMap { conversationKey(of: $0) }))
    }

    /// Apply one action now (Live Activity buttons share the notification path). The
    /// thread's banner goes first — not on the post-sync reconciliation.
    func perform(_ action: PendingAction) async {
        removeDelivered(conversationKeys: [action.conversationKey])
        enqueue(action)
        await drainPendingActions()
    }

    /// Actions that make a thread's banner stale the moment they're taken.
    static let bannerClearingVerbs: Set<String> = [
        ConversationAction.archive.verb, ConversationAction.trash.verb,
        ConversationAction.spam.verb, ConversationAction.markRead.verb,
    ]

    /// The drain in flight, if any. Every tap used to start its own pass over the
    /// whole queue, so taps landing while an action was still running re-sent every
    /// queued action (and the last pass to finish overwrote the queue).
    private var draining: Task<Void, Never>?

    private func enqueue(_ action: PendingAction) {
        var queue = pendingActions()
        // A repeat tap on the same thread (the card shows it again until the first
        // tap lands) is the same action — keep one.
        guard !queue.contains(action) else { return }
        queue.append(action)
        savePendingActions(queue)
    }

    private func savePendingActions(_ queue: [PendingAction]) {
        UserDefaults.standard.set(queue.isEmpty ? nil : try? JSONEncoder().encode(queue), forKey: Self.pendingActionsKey)
    }

    private func pendingActions() -> [PendingAction] {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingActionsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingAction].self, from: data)) ?? []
    }

    /// Apply every queued notification-button action; drop each on success. Called
    /// right after a button press and again at launch (Inbox2App), so an action
    /// taken while the process was dead is applied as soon as the engine is up.
    /// Waits briefly for the engine / cloud session — on a background launch they
    /// are still being constructed when the delegate fires.
    /// One pass at a time: a caller arriving mid-pass waits for it, then drains
    /// whatever is still queued (its own action included).
    func drainPendingActions() async {
        while let running = draining { await running.value }
        // The pass clears `draining` itself, before it completes. Clearing it after
        // `await pass.value` livelocked the main actor: a waiter resuming first saw
        // the finished task still set, its await returned at once, and it spun
        // forever (watchdog 0x8BADF00D on a second card tap).
        let pass = Task { await drainOnce(); draining = nil }
        draining = pass
        await pass.value
    }

    private func drainOnce() async {
        guard !pendingActions().isEmpty else { return }
        for _ in 0..<50 where PushRegistrar.engine == nil || PushRegistrar.cloud?.state == .loading {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let engine = PushRegistrar.engine, let cloud = PushRegistrar.cloud else {
            Log.action.info("notification action: engine not up yet; left queued")
            return
        }
        var done: [PendingAction] = []
        for a in pendingActions() {
            let ok: Bool
            if let orgId = a.orgId {
                ok = await cloud.perform(conversationIds: [a.conversationKey], action: a.verb, orgId: orgId)
                if ok { await cloud.refreshUnreadCount() }
            } else if let acct = a.accountKey {
                ok = await engine.perform(accountKey: acct, conversationKeys: [a.conversationKey], action: a.verb)
            } else {
                ok = true   // nothing to route it to; drop rather than retry forever
            }
            Log.action.info("notification action \(a.verb, privacy: .public) on \(a.conversationKey, privacy: .public): \(ok ? "ok" : "failed")")
            if ok { done.append(a) }
        }
        // Drop only what this pass applied — a tap enqueued meanwhile stays queued.
        savePendingActions(pendingActions().filter { !done.contains($0) })
        await MailActivityManager.shared.refresh()
    }

    // Show banners even when the app is in the foreground.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // Tapping a notification opens its conversation (the inbox consumes the key).
    // Local notifications carry `conversationKey`; a visible APNs push (MX-pool
    // mail, sent by Rails) carries its `conversation_id` as a custom payload key.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let conversationKey = (userInfo["conversationKey"] as? String) ?? (userInfo["conversation_id"] as? String)
        let trash = conversationKey.map {
            PendingAction(verb: ConversationAction.trash.verb, conversationKey: $0,
                          accountKey: (userInfo["accountKey"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          orgId: userInfo["organization_id"] as? String)
        }
        // Copy & delete: the code without spaces/dashes ("123-456" → "123456"), then
        // the thread goes to the trash through the normal queue. Runs in the background.
        if response.actionIdentifier == Self.copyCodeAction, let code = userInfo["otp_code"] as? String {
            Task { @MainActor in
                UIPasteboard.general.string = code.filter { $0 != " " && $0 != "-" }
                if let trash { await self.perform(trash) }
                completionHandler()
            }
            return
        }
        // Open & delete (a .foreground action): trash only once the link actually opened.
        if response.actionIdentifier == Self.openLinkAction,
           let link = userInfo["otp_link"] as? String, let url = URL(string: link) {
            Task { @MainActor in
                // A cold launch delivers this before the scene is active; open() fails until it is.
                for _ in 0..<20 where UIApplication.shared.applicationState != .active {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let opened = await UIApplication.shared.open(url)
                Log.action.info("otp link open: \(opened ? "ok" : "failed")")
                if opened, let trash { await self.perform(trash) }
                completionHandler()
            }
            return
        }
        // An action button. iOS runs this in the background (the app is launched or
        // woken without coming to the foreground) and gives us until the completion
        // handler to finish — enough for the write-back. Channel actions are durable
        // in the engine (local state now, provider write-back queued + retried), MX
        // actions are one API call.
        if Self.mailActions.contains(where: { $0.action.verb == response.actionIdentifier }),
           let key = (userInfo["conversationKey"] as? String) ?? (userInfo["conversation_id"] as? String) {
            let action = PendingAction(verb: response.actionIdentifier, conversationKey: key,
                                       accountKey: (userInfo["accountKey"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                       orgId: userInfo["organization_id"] as? String)
            Task { @MainActor in
                self.enqueue(action)
                await self.drainPendingActions()
                completionHandler()
            }
            return
        }
        if let key = (userInfo["conversationKey"] as? String) ?? (userInfo["conversation_id"] as? String) {
            Task { @MainActor in self.pendingConversationKey = key }
        }
        // A meeting alarm opens its event instead (Calendar tab → detail sheet).
        if let key = userInfo["calendarEventKey"] as? String {
            Task { @MainActor in self.pendingEventKey = key }
        }
        completionHandler()
    }
}
