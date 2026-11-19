import SwiftUI
import UIKit

/// APNs plumbing (docs/Cloud-Push.md "Mobile push"): registers the device token
/// with the API and handles incoming pushes.
///
/// Three push kinds arrive from Rails:
/// - silent `channel_sync` (content-available, no alert): a Gmail/Microsoft mailbox
///   changed. We run the same all-accounts sync as BGAppRefresh; the engine's
///   `new-message` events post the real (local, content-rich) notifications.
/// - silent `meta_event` (content-available): a Meta (Instagram/Messenger/WhatsApp)
///   relay nudge carrying a buffer key; we fetch + verify + apply that one event
///   (WhatsApp has no pull API), and the engine's `new-message` posts the alert.
/// - silent `zones_changed` (content-available): the user's zones or a zone
///   dismissal changed on another device (docs/Calendar.md "Zones"). An optional
///   `dismissed` occurrence id is applied at once; then ZoneStore refetches + re-arms.
/// - visible `new_message` (MX-pool mail): the system shows it directly; a tap is
///   routed by NotificationManager via `userInfo["conversation_id"]`.
///
/// Registration POSTs the hex token to `/push-devices` with the same bearer the
/// image proxy uses (personal API key, else MX session token). Debug builds get
/// sandbox APNs tokens, so they register `environment: "sandbox"` — Rails routes
/// them through the sandbox gateway.
final class PushRegistrar: NSObject, UIApplicationDelegate {
    /// Set by Inbox2App once the engine exists, so the silent-push handler can sync.
    static weak var engine: EngineModel?
    /// Same weak-static bridge for the cloud session: a background sync recomputes
    /// only the CHANNEL half of the badge and re-applies channel + last-known
    /// domain, so without refreshing the domain half too it would overwrite a
    /// server-pushed count with a stale one.
    static weak var cloud: CloudSession?

    private static let lastRegisteredKey = "inbox2_push_last_registered_token"
    /// Last channel-unread value reported to the API — so we only POST on change.
    private static let reportedUnreadKey = "inbox2_push_reported_channel_unread"
    /// Most recent APNs token (not a secret) — kept so a registration deferred for
    /// lack of a bearer can be retried later without waiting for a new token callback.
    private static let deviceTokenKey = "inbox2_push_device_token"
    /// Push-to-start token for the Mail Live Activity, kept so a report deferred for
    /// lack of a device token / bearer is retried on the next registration.
    private static let liveActivityStartKey = "inbox2_live_activity_start_token"
    /// Start token the API has acknowledged — so a report that failed (API not yet
    /// deployed, offline) is retried on the next foreground, and a successful one isn't.
    private static let liveActivityReportedKey = "inbox2_live_activity_reported_start_token"

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Silent pushes need no user permission; alert permission is requested
        // separately by NotificationManager at engine start.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Log.cloud.info("APNs device token received")
        UserDefaults.standard.set(token, forKey: Self.deviceTokenKey)
        Task { await Self.registerWithAPI(token: token) }
    }

    /// Retry a deferred registration (called when the app becomes active) — a no-op
    /// once the current token has been registered.
    static func ensureRegistered() async {
        guard let token = UserDefaults.standard.string(forKey: deviceTokenKey) else { return }
        await registerWithAPI(token: token)
        if let start = UserDefaults.standard.string(forKey: liveActivityStartKey),
           UserDefaults.standard.string(forKey: liveActivityReportedKey) != start {
            await reportLiveActivity(startToken: start)
        }
    }

    /// Report this device's offline-channel unread to the API so a push that lands
    /// while the app is closed carries an accurate badge (domain unread + this).
    /// POSTs only on change, and only once the device token + a bearer exist.
    static func reportChannelUnread(_ count: Int) async {
        guard (UserDefaults.standard.object(forKey: reportedUnreadKey) as? Int) != count else { return }
        guard let token = UserDefaults.standard.string(forKey: deviceTokenKey) else { return }
        guard let bearer = ImageProxy.bearer(apiKey: Keychain.get(PrivacyStore.apiKeyAccount)) else { return }
        guard let url = URL(string: AppConfig.apiBase + "/push-devices/unread") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token, "channel_unread": count])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return }
            // A 404 means the API has no PushDevice row for this token — e.g. the
            // backend was reset (fresh prod database) while our local "already
            // registered" marker survived, so registerWithAPI keeps short-circuiting
            // and APNs never resumes. Clear the stale marker and re-register.
            if http.statusCode == 404 {
                Log.cloud.info("channel-unread 404 — device unknown to API, re-registering")
                UserDefaults.standard.removeObject(forKey: lastRegisteredKey)
                await registerWithAPI(token: token)
                return
            }
            guard (200..<300).contains(http.statusCode) else { return }
            UserDefaults.standard.set(count, forKey: reportedUnreadKey)
        } catch {
            Log.cloud.info("channel-unread report failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Report ActivityKit tokens for the Mail Live Activity (docs/Cloud-Push.md "Live
    /// Activity"): the push-to-start token (long-lived) and the running card's update
    /// token (nil once it ends). Each is sent only when given, so they're independent.
    static func reportLiveActivity(startToken: String? = nil, activityToken: String?? = nil) async {
        if let startToken { UserDefaults.standard.set(startToken, forKey: liveActivityStartKey) }
        guard let token = UserDefaults.standard.string(forKey: deviceTokenKey),
              let bearer = ImageProxy.bearer(apiKey: Keychain.get(PrivacyStore.apiKeyAccount)),
              let url = URL(string: AppConfig.apiBase + "/push-devices/live-activity") else { return }
        var body: [String: Any] = ["token": token]
        if let startToken { body["start_token"] = startToken }
        if let activityToken { body["activity_token"] = activityToken ?? NSNull() }
        guard body.count > 1 else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            Log.cloud.info("live-activity tokens reported: HTTP \(status)")
            if let startToken, (200..<300).contains(status) {
                UserDefaults.standard.set(startToken, forKey: liveActivityReportedKey)
            }
        } catch {
            Log.cloud.info("live-activity token report failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Ask Rails to push-start the Mail Live Activity with this content — the only
    /// way a card can appear while the app is in the background.
    static func requestLiveActivityStart(_ state: MailActivityAttributes.ContentState) async {
        guard let token = UserDefaults.standard.string(forKey: deviceTokenKey),
              let bearer = ImageProxy.bearer(apiKey: Keychain.get(PrivacyStore.apiKeyAccount)),
              let url = URL(string: AppConfig.apiBase + "/push-devices/live-activity/start") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "content_state": ["conversationKey": state.conversationKey, "accountKey": state.accountKey, "orgId": state.orgId,
                              "sender": state.sender, "subject": state.subject, "snippet": state.snippet]
        ])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            Log.cloud.info("live-activity start requested: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        } catch {
            Log.cloud.info("live-activity start request failed: \(String(describing: error), privacy: .public)")
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.cloud.info("APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler reply: @escaping (UIBackgroundFetchResult) -> Void) {
        // iOS allows ~30 s per wake and penalises apps that overrun. Every push type
        // answers by 25 s, even if its work hangs.
        var finished = false
        let completionHandler: (UIBackgroundFetchResult) -> Void = { result in
            guard !finished else { return }
            finished = true
            reply(result)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            completionHandler(.newData)
        }
        let type = userInfo["type"] as? String
        // Zones are cloud-only — no engine needed, so handle before that guard.
        if type == "zones_changed" {
            let dismissedId = userInfo["dismissed"] as? String
            Log.cloud.info("silent zones_changed push (dismissed: \(dismissedId ?? "-", privacy: .public))")
            Task { @MainActor in
                await ZoneStore.shared.syncFromPush(dismissed: dismissedId)
                completionHandler(.newData)
            }
            return
        }
        guard let engine = Self.engine else {
            completionHandler(.failed)
            return
        }
        // Any wake is a chance for the MX mirror to catch up (docs/MX-Sync.md) — iOS
        // has no socket, so pushes and foregrounding are its only live signals.
        Task { @MainActor in MxMirror.shared.kickAll() }
        switch type {
        case "channel_sync":
            Log.cloud.info("silent channel_sync push — syncing")
            Task { @MainActor in
                let synced = await engine.syncAllAndWait()
                // Keep the domain half current too — the sync below re-applies the
                // badge from both halves.
                await Self.cloud?.refreshUnreadCount()
                // Path B: Rails never sees channel mail, so a desktop delete
                // can't be pushed as a removal. After the wake-sync the local DB
                // reflects it — clear any on-screen banner whose conversation no
                // longer warrants one (gone / trashed / archived / spam).
                await Self.reconcileDeliveredNotifications(engine: engine)
                // Same reconciliation for the lock-screen card: advance / end it, or
                // ask Rails to start one for mail that just landed.
                await MailActivityManager.shared.refresh()
                completionHandler(synced ? .newData : .noData)
            }
        case "remove_notification":
            // Path A: an MX conversation left the inbox on another device.
            Log.cloud.info("remove_notification push — clearing banner")
            guard let key = userInfo["conversation_id"] as? String else {
                completionHandler(.noData)
                return
            }
            Task { @MainActor in
                NotificationManager.shared.removeDelivered(conversationKeys: [key])
                completionHandler(.noData)
            }
        case "meta_event":
            // Meta webhook relay: fetch the buffered payload, verify the HMAC
            // locally, normalize, apply. See docs/Cloud-Push.md (Meta).
            guard let key = userInfo["event_key"] as? String else {
                completionHandler(.noData)
                return
            }
            Log.cloud.info("silent meta_event push — ingesting")
            Task { @MainActor in
                let applied = await engine.ingestMetaEvent(eventKey: key)
                completionHandler(applied ? .newData : .noData)
            }
        default:
            completionHandler(.noData)
        }
    }

    /// Drop delivered notifications whose conversation no longer warrants one —
    /// deleted/merged (gone from the store), trashed/archived/spam (left the
    /// inbox), or already read, e.g. dealt with on another device since the
    /// banner appeared.
    /// Reconciles against the local SQLite the sync just refreshed; covers local
    /// channels (no Rails removal push) and is a harmless backstop for MX mail.
    @MainActor
    static func reconcileDeliveredNotifications(engine: EngineModel) async {
        let onScreen = await NotificationManager.shared.deliveredConversationKeys()
        guard !onScreen.isEmpty else { return }
        let stale: [String] = await engine.store.read { store in
            onScreen.filter { key in
                guard let conv = store.conversation(key: key) else { return true }
                // Gone, left the inbox (trash/archive/spam), or already read.
                return ConvStatusValue.inboxHidden.contains(conv.status) || !conv.unread
            }
        }
        guard !stale.isEmpty else { return }
        NotificationManager.shared.removeDelivered(conversationKeys: stale)
    }

    /// POST the token to the API (idempotent upsert). Skipped without a bearer —
    /// retried on the next launch/token callback once the user has signed in or
    /// pasted an API key.
    static func registerWithAPI(token: String) async {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        // Dedupe on token+environment+API base: a build-config change flips the
        // environment for the same token, and a change of API origin (or a backend
        // reset that drops our device row) must force a re-register too.
        let registrationMarker = "\(token)|\(environment)|\(AppConfig.apiBase)"
        guard UserDefaults.standard.string(forKey: lastRegisteredKey) != registrationMarker else { return }
        guard let bearer = ImageProxy.bearer(apiKey: Keychain.get(PrivacyStore.apiKeyAccount)) else {
            Log.cloud.info("push registration deferred — no API bearer yet")
            return
        }
        guard let url = URL(string: AppConfig.apiBase + "/push-devices") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "token": token,
            "platform": "ios",
            "environment": environment,
            "device_name": await UIDevice.current.name
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.cloud.info("push registration HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            UserDefaults.standard.set(registrationMarker, forKey: lastRegisteredKey)
            Log.cloud.info("registered APNs token with the API (\(environment))")
            // A fresh device row has no ActivityKit tokens — re-send the one we hold.
            UserDefaults.standard.removeObject(forKey: liveActivityReportedKey)
            if let start = UserDefaults.standard.string(forKey: liveActivityStartKey) {
                await reportLiveActivity(startToken: start)
            }
        } catch {
            Log.cloud.info("push registration failed: \(String(describing: error), privacy: .public)")
        }
    }
}
