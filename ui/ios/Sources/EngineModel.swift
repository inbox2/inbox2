import Foundation
import Combine
import os

/// Session-scoped LRU cache of downloaded attachment bytes, keyed by
/// account:message:attachment. Files can be large, so only a handful are kept.
actor AttachmentByteCache {
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private let maxEntries = 12
    /// Evicting past this keeps a few big files from riding along into suspension.
    /// The newest entry always stays, however large: it is the file being opened.
    private let maxBytes = 64 << 20
    private var totalBytes = 0

    func get(_ key: String) -> Data? { cache[key] }

    func set(_ key: String, _ data: Data) {
        if let old = cache[key] {
            totalBytes -= old.count
            order.removeAll { $0 == key }
        }
        order.append(key)
        cache[key] = data
        totalBytes += data.count
        while order.count > 1, order.count > maxEntries || totalBytes > maxBytes {
            let evicted = order.removeFirst()
            totalBytes -= cache.removeValue(forKey: evicted)?.count ?? 0
        }
    }

    /// Dropped on background; the bytes are still on disk (`attachmentCacheURL`).
    func removeAll() {
        cache.removeAll()
        order.removeAll()
        totalBytes = 0
    }
}

/// Owns the shared Rust [`InboxEngine`] and surfaces its state to SwiftUI. The
/// engine opens the local SQLite store, starts its poll + write-back loops, and
/// boots any connected accounts; events flow back through [`EngineListener`].
@MainActor
final class EngineModel: ObservableObject {
    @Published var status: String = "starting…"
    @Published var accounts: [AccountRow] = []
    /// An account whose credentials went dead (`needs_reauth`) and the user should
    /// be told about. The root view presents an alert from this; `nil` once
    /// dismissed. Rate-limited by the engine to one prompt per account per 5
    /// minutes (see `claimReauthPrompt`), so a dead token doesn't nag on every
    /// sync tick, foreground and relaunch.
    @Published var reauthPrompt: AccountRow?
    /// Diagnostics only (Settings › Engine diagnostics), deliberately NOT
    /// `@Published`: engine events arrive per sync batch, and republishing on each
    /// one re-rendered every view observing the engine — which rebuilt the
    /// conversation rows' context menus while one was open and ate the tap, so
    /// Trash took two or three goes. `dataVersion` below is the throttled signal
    /// the UI is meant to follow.
    var lastEvent: String = "—"
    var eventCount: Int = 0
    /// Bumped whenever the engine reports a data-changing event (sync completed /
    /// new message / calendar change). Views observe it to re-query the store.
    @Published var dataVersion: Int = 0

    /// One triage result landing (`triage-updated`): the row's new label + one-line
    /// summary. Views patch the matching row in place instead of re-querying the
    /// store — the event fires once per labeled thread, which during a catch-up
    /// drain is continuous; a full reload per event made the whole app sluggish.
    /// `seq` makes consecutive patches distinct for `onChange`.
    struct TriagePatch: Equatable {
        let key: String
        let label: String?
        /// Jev's 0–4 attention score, nil when not scored.
        let priority: Double?
        let summaryShort: String?
        let seq: Int
    }
    @Published var triagePatch: TriagePatch?
    private var triagePatchSeq = 0

    /// Shortest gap between two event-driven `dataVersion` bumps. A sync cycle emits
    /// one `sync` event per FOLDER per ACCOUNT (4 accounts × ~6 folders ≈ 24 events in
    /// a burst), and every bump re-ran each list's `.task(id:)`: a fresh SQLite read,
    /// a re-issued `GET /orgs/…/conversations`, and cancellation of the in-flight one
    /// (the `-999 "cancelled"` storm in the logs) — ~40 reloads per cycle for one
    /// meaningful change. Leading-edge throttle with a trailing catch-up, so the first
    /// event still lands instantly and the last one is never lost.
    private static let dataBumpInterval: TimeInterval = 1.0
    private var lastDataBump = Date.distantPast
    private var dataBumpTask: Task<Void, Never>?

    /// True while a user-kicked sync is in flight — drives the header sync spinner.
    /// Set when `sync()` starts; cleared a moment after sync events stop flowing.
    @Published var syncing = false
    private var syncSettle: Task<Void, Never>?

    /// Live Bridge model-download state, keyed by model id, fed by `model-download`
    /// engine events. The Bridge voice settings render progress + completion from it.
    @Published var modelDownloads: [String: ModelDownload] = [:]

    /// Async triage/summary progress (in-window conversations classified so far),
    /// fed by `triage-progress` events. Drives the Settings + Bridge progress bars.
    @Published var triage: TriageState = .empty
    /// The selected processing window (`1_month` … `everything`), read from the
    /// engine at start and updated via `setProcessingWindow`.
    @Published var processingWindow: String = ProcessingWindow.default.rawValue

    /// HuggingFace access token for gated model downloads (none in the current manifest). Persisted in
    /// the Keychain; pushed to the core so its downloader can authenticate. Setting it
    /// re-pushes to a running engine immediately.
    @Published var hfToken: String = "" {
        didSet {
            guard hfToken != oldValue else { return }
            let trimmed = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { Keychain.delete(Self.hfTokenAccount) }
            else { Keychain.set(trimmed, for: Self.hfTokenAccount) }
            engine?.setHfToken(token: trimmed.isEmpty ? nil : trimmed)
        }
    }
    private static let hfTokenAccount = "hf_token"

    /// The user's Jev (TypeSafe) key — local-channel triage (label, priority,
    /// Space). Keychain `typesafe_api_key` (docs/Triage.md); pushed to the engine at
    /// launch and on every change. Set only after `validateJevKey` passes.
    @Published var jevKey: String = "" {
        didSet {
            guard jevKey != oldValue else { return }
            let trimmed = jevKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { Keychain.delete(Self.jevKeyAccount) }
            else { Keychain.set(trimmed, for: Self.jevKeyAccount) }
            engine?.setJevKey(key: trimmed.isEmpty ? nil : trimmed)
            if let engine { loadTriageState(from: engine) }
        }
    }
    private static let jevKeyAccount = "typesafe_api_key"
    var hasJevKey: Bool { !jevKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasHFToken: Bool { !hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Read-only view of the local store the engine writes. Views read mail
    /// directly from here; mutations go through `perform(action:)`.
    let store: InboxStore

    private var engine: InboxEngine?
    /// For `MxMirror` (docs/MX-Sync.md) — the MX mirror's verbs live on the engine.
    var mxEngine: InboxEngine? { engine }
    private var listener: EngineListener?

    /// The one engine per process. Inbox2App's @StateObject IS this instance; the
    /// weak PushRegistrar bridge points at it from App.init, so a process iOS
    /// launches in the background (Live Activity button, notification action,
    /// silent push) has an engine before any SwiftUI view exists.
    static let shared = EngineModel()

    init() {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("inbox2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dataDir = dir
        self.store = InboxStore(dbPath: dir.appendingPathComponent("inbox2.db").path)
        self.hfToken = Keychain.get(Self.hfTokenAccount) ?? ""
        self.jevKey = Keychain.get(Self.jevKeyAccount) ?? ""
        start()
    }

    private let dataDir: URL

    /// Engine events that mean "the local store changed → re-read it".
    private static let dataChangingEvents: Set<String> = ["sync", "new-message", "calendar-changed"]

    /// Coalesce a burst of data-changing engine events into at most one store re-read
    /// per `dataBumpInterval`. Fires immediately when the last bump is old enough
    /// (so a single sync still feels instant), otherwise arms one trailing bump — the
    /// tail of a burst is never dropped. User-initiated writes (`perform`, `send`, …)
    /// bump `dataVersion` directly and are deliberately NOT throttled.
    private func scheduleDataBump() {
        let since = Date().timeIntervalSince(lastDataBump)
        guard since < Self.dataBumpInterval else {
            applyDataBump()
            return
        }
        guard dataBumpTask == nil else { return }   // a trailing bump is already armed
        dataBumpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.dataBumpInterval - since))
            guard let self, !Task.isCancelled else { return }
            self.dataBumpTask = nil
            self.applyDataBump()
        }
    }

    private func applyDataBump() {
        lastDataBump = Date()
        store.reopenIfNeeded()
        dataVersion += 1
        refreshAccounts()
        Task { await refreshChannelBadge() }
    }

    private func start() {
        let listener = EngineListener { [weak self] event, payload in
            Task { @MainActor in
                guard let self else { return }
                self.lastEvent = event
                self.eventCount += 1
                Log.sync.debug("event=\(event, privacy: .public) payloadLen=\(payload.count)")
                if Self.dataChangingEvents.contains(event) {
                    self.scheduleDataBump()
                }
                // Each sync event re-arms a short stop, so the spinner ends shortly
                // after the last sync event lands.
                if event == "sync" && self.syncing { self.scheduleSyncStop(after: 1.5) }
                if event == "new-message" {
                    NotificationManager.shared.postNewMessage(payloadJSON: payload)
                }
                if event == "model-download", let d = ModelDownload(payloadJSON: payload) {
                    self.modelDownloads[d.id] = d
                }
                // Triage progress ticks update the bar only (high frequency — no
                // store re-query). A triage-updated event means a conversation's
                // label/summaries changed, so bump dataVersion to refresh badges.
                if event == "triage-progress", let t = TriageState(payloadJSON: payload) {
                    self.triage = t
                }
                if event == "triage-updated",
                   let data = payload.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let key = obj["conversationKey"] as? String {
                    self.triagePatchSeq += 1
                    self.triagePatch = TriagePatch(key: key,
                                                   label: obj["label"] as? String,
                                                   priority: (obj["priority"] as? NSNumber)?.doubleValue,
                                                   summaryShort: obj["summaryShort"] as? String,
                                                   seq: self.triagePatchSeq)
                }
            }
        }
        self.listener = listener

        do {
            // Pass the device's reachable Rails base so the engine refreshes OAuth
            // tokens against it — not the `localhost` URL seeded from a desktop dump.
            let engine = try InboxEngine(dataDir: dataDir.path, listener: listener, llm: BridgeLLM(dataDir: dataDir), cloudApiBase: AppConfig.apiBase)
            self.engine = engine
            self.status = "running"
            Log.engine.info("engine started; data dir \(self.dataDir.path, privacy: .public)")
            // Tell the model manager what device it's on so it can resolve which
            // native lanes (Apple speech / Foundation Models) exist here.
            pushDeviceProfile(to: engine)
            if hasHFToken { engine.setHfToken(token: hfToken) }
            if hasJevKey { engine.setJevKey(key: jevKey) }
            // Re-install the persisted prompt overrides (dev-mode editor). The core
            // holds overrides in memory only, so each launch re-applies the file;
            // invalid content is logged and skipped — never fatal (the embedded
            // defaults keep the Bridge and triage running).
            if let text = try? String(contentsOf: dataDir.appendingPathComponent("prompts.toml"), encoding: .utf8) {
                do { try engine.setPromptOverrides(tomlText: text) }
                catch { Log.engine.error("prompt overrides rejected at launch: \(String(describing: error), privacy: .public)") }
            }
            NotificationManager.shared.requestAuthorization()
            refreshAccounts()
            loadTriageState(from: engine)
            TriageLabelNames.local = Dictionary(triageLabels().map { ($0.slug, $0.name) },
                                                uniquingKeysWith: { a, _ in a })
            // Warm the contacts autocomplete cache off the main thread. The first
            // `contacts()` call does a full-table scan + address parse (118K rows on a
            // large account); doing it here means the later synchronous reads (Bridge
            // attendee resolution) hit the warm cache instead of blocking the UI.
            Task { await store.read { _ = $0.contacts() } }
        } catch {
            self.status = "error: \(error)"
            Log.engine.error("engine start failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Push the current device capability profile to the core. Apple Intelligence
    /// availability is queried live here (not cached), so re-running this picks up a
    /// model that finished warming, or AI the user enabled in Settings after launch.
    private func pushDeviceProfile(to engine: InboxEngine) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        engine.setDeviceProfile(profile: FfiDeviceProfile(
            os: "ios",
            osMajor: UInt32(v.majorVersion),
            osMinor: UInt32(v.minorVersion),
            appleIntelligence: AppleLLM().isAvailable(),
            androidNativeSpeech: false
        ))
    }

    /// Re-evaluate device capabilities (call on foreground): the On-device lane is no
    /// longer pinned to whatever was true at the instant the engine first booted.
    func refreshDeviceProfile() {
        guard let engine else { return }
        pushDeviceProfile(to: engine)
    }

    func refreshAccounts() {
        guard let engine else { return }
        // Off the main actor: `listAccountsJson` serializes on the engine's store
        // mutex, so while the sync/triage workers are writing this call can wait
        // on them — never park the UI thread on it.
        Task.detached { [weak self] in
            let result = Result { try engine.listAccountsJson() }
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let json):
                    let rows = AccountRow.parse(json)
                    self.accounts = rows
                    self.detectReauth(rows)
                    Log.engine.info("accounts: \(rows.count)")
                case .failure(let error):
                    self.status = "list error: \(error)"
                    Log.engine.error("listAccounts failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Raise a re-auth alert for an account whose tokens died. The engine holds the
    /// rate limit (at most one prompt per account per 5 minutes, persisted), so a
    /// dead token no longer re-prompts on every refresh, foreground and relaunch —
    /// the Settings badge keeps showing it in the meantime.
    private func detectReauth(_ rows: [AccountRow]) {
        guard reauthPrompt == nil,
              let engine,
              let next = rows.first(where: { $0.needsReauth })
        else { return }
        // The claim takes the store mutex — off the main actor, like listAccountsJson.
        Task.detached { [weak self] in
            guard engine.claimReauthPrompt(accountKey: next.id) else { return }
            await MainActor.run {
                guard let self, self.reauthPrompt == nil else { return }
                self.reauthPrompt = next
                Log.engine.info("account needs re-auth: \(next.email)")
            }
        }
    }

    // MARK: - Async triage + multi-level summaries

    /// Read the current window + progress snapshot (called at start; live updates
    /// then arrive via `triage-progress` events).
    private func loadTriageState(from engine: InboxEngine) {
        // Off the main actor: both reads wait on the store mutex while sync writes.
        Task.detached { [weak self] in
            let window = try? engine.getProcessingWindow()
            let progress = (try? engine.triageProgress()).flatMap { TriageState(payloadJSON: $0) }
            await MainActor.run {
                guard let self else { return }
                if let window { self.processingWindow = window }
                if let progress { self.triage = progress }
            }
        }
    }

    // MARK: - Jev triage (labels, key, Space taxonomy)

    /// nil = the key works; otherwise the core's user-displayable message.
    func validateJevKey(_ key: String) async -> String? {
        guard let engine else { return "Still starting up. Try again in a moment." }
        return await Task.detached(priority: .userInitiated) {
            do { try engine.validateJevKey(key: key); return nil }
            catch let FfiError.Engine(msg) { return msg }
            catch { return error.localizedDescription }
        }.value
    }

    /// The local label list (built-ins + custom), position order.
    func triageLabels() -> [TriageLabelDef] {
        guard let engine, let json = try? engine.getTriageLabels(),
              let labels = try? JSONDecoder().decode([TriageLabelDef].self, from: Data(json.utf8))
        else { return [] }
        return labels
    }

    /// Replace the local label list; returns the stored list or the core's validation error.
    func setTriageLabels(_ labels: [TriageLabelDef]) -> Result<[TriageLabelDef], FfiError> {
        guard let engine else { return .failure(.Engine("Still starting up. Try again in a moment.")) }
        do {
            let json = String(decoding: try JSONEncoder().encode(labels), as: UTF8.self)
            let stored = try JSONDecoder().decode([TriageLabelDef].self,
                                                  from: Data(try engine.setTriageLabels(labelsJson: json).utf8))
            TriageLabelNames.local = Dictionary(stored.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a })
            return .success(stored)
        } catch let e as FfiError { return .failure(e) }
        catch { return .failure(.Engine(error.localizedDescription)) }
    }

    /// Push the org's classifiable Spaces (`[{slug,name,description,not_for}]`) so
    /// Jev can file local-channel threads into them (docs/Triage.md "Spaces").
    func setSpaceTaxonomy(_ spacesJSON: String) {
        guard let engine else { return }
        // Off the main actor: it can requeue the triage backlog under the store mutex.
        Task.detached {
            do { try engine.setSpaceTaxonomy(spacesJson: spacesJSON) }
            catch { Log.engine.error("setSpaceTaxonomy failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Push the user's AI model selection to the background triage worker so it
    /// classifies/summarizes with the same model the Bridge speaks with. Call at
    /// launch and whenever the Settings selection changes.
    func setAiConfig(_ config: FfiBridgeConfig) {
        engine?.setAiConfig(config: config)
    }

    /// Change how far back mail is classified/summarized. Widening backfills the
    /// newly-in-window backlog. Updates `processingWindow` optimistically.
    func setProcessingWindow(_ window: ProcessingWindow) {
        guard let engine else { return }
        let previous = processingWindow
        processingWindow = window.rawValue
        Task.detached {
            do { try engine.setProcessingWindow(window: window.rawValue) }
            catch {
                Log.engine.error("setProcessingWindow failed: \(String(describing: error), privacy: .public)")
                await MainActor.run { self.processingWindow = previous }
            }
        }
    }

    // MARK: Open tracking (docs/Open-Tracking.md)

    /// Enable/disable open tracking for a channel + set its custom tracking host
    /// (nil = the inbox2 default). Fire-and-forget, mirrors setProcessingWindow.
    func setOpenTracking(accountKey: String, enabled: Bool, trackDomain: String?) {
        guard let engine else { return }
        Task.detached {
            do { try engine.setOpenTracking(accountKey: accountKey, enabled: enabled, trackDomain: trackDomain) }
            catch { Log.engine.error("setOpenTracking failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Current open-tracking settings for a channel.
    func openTrackingSettings(accountKey: String) async -> (enabled: Bool, trackDomain: String?) {
        guard let engine else { return (false, nil) }
        return await Task.detached {
            do {
                let json = try engine.openTrackingSettingsJson(accountKey: accountKey)
                guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return (false, nil) }
                let td = obj["track_domain"] as? String
                return ((obj["enabled"] as? Bool) ?? false, (td?.isEmpty == false) ? td : nil)
            } catch {
                Log.engine.error("openTrackingSettings failed: \(String(describing: error), privacy: .public)")
                return (false, nil)
            }
        }.value
    }

    /// Pull the user's cloud-synced per-channel open-tracking config and mirror it
    /// into the local engine (matched to connected accounts by email), so pixel
    /// injection honors settings saved on their other devices (docs/Open-Tracking.md).
    /// Fire-and-forget from launch — a network call off the main path, so it never
    /// blocks startup.
    func mirrorChannelTracking(cloud: CloudSession) async {
        guard cloud.isSignedIn else { return }
        let channels = await cloud.channelTracking()
        guard !channels.isEmpty else { return }
        let byEmail = Dictionary(accounts.map { ($0.email.lowercased(), $0.id) }, uniquingKeysWith: { a, _ in a })
        for ch in channels {
            guard let key = byEmail[ch.emailAddress.lowercased()] else { continue }
            setOpenTracking(accountKey: key, enabled: ch.openTrackingEnabled, trackDomain: ch.trackDomain)
        }
    }

    /// Open history (who/when/where) for a sent message, via its embedded token.
    func messageOpens(messageKey: String) async -> [MessageOpen] {
        guard let engine else { return [] }
        return await Task.detached {
            do {
                let json = try engine.messageOpensJson(messageKey: messageKey)
                guard let arr = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
                return arr.map { o in
                    MessageOpen(openedAt: o["opened_at"] as? String ?? "",
                                ip: o["ip"] as? String,
                                geoCountry: o["geo_country"] as? String,
                                geoCity: o["geo_city"] as? String,
                                proxied: (o["proxied"] as? Bool) ?? false,
                                proxyKind: o["proxy_kind"] as? String,
                                userAgent: o["user_agent"] as? String)
                }
            } catch {
                Log.reader.error("messageOpens failed: \(String(describing: error), privacy: .public)")
                return []
            }
        }.value
    }

    /// Apply a conversation action through the engine (durable provider write-back),
    /// off the main thread. Bumps `dataVersion` on success so list views re-read from
    /// the store — important for in-place changes like `mark_read` that don't remove
    /// the row (so there's no optimistic mutation to mask a stale row). Returns success
    /// so the caller can roll back its optimistic UI on failure.
    func perform(accountKey: String, conversationKeys: [String], action: String) async -> Bool {
        guard let engine else { return false }
        Log.action.info("perform \(action, privacy: .public) on \(conversationKeys.count) conv(s) acct=\(accountKey, privacy: .public)")
        let ok = await Task.detached {
            do {
                try engine.performAction(accountKey: accountKey, conversationKeys: conversationKeys, action: action)
                return true
            } catch {
                Log.action.error("perform \(action, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if ok {
            await MainActor.run { self.dataVersion += 1 }
            // Unread-affecting actions (mark read/unread, archive/trash) must move the
            // badge NOW — not on the next sync event. Without this the count lags the
            // row change (and lags undo), only catching up when a later sync fires
            // (~when the undo toast clears). refreshChannelBadge is a cheap COUNT.
            await refreshChannelBadge()
            await MailActivityManager.shared.refresh()
            // Drop the thread's lock-screen banner now — the post-sync reconcile would
            // only get to it on the next wake.
            if NotificationManager.bannerClearingVerbs.contains(action) {
                NotificationManager.shared.removeDelivered(conversationKeys: conversationKeys)
            }
        }
        return ok
    }

    /// Route a conversation action to the right backend: the cloud API for domain
    /// (`org_…`/`dom_…`) threads, else the engine write-back above — the one router
    /// behind the inbox list and the reader. Returns success. Unsupported domain
    /// actions (flag/quadrant) are a no-op (false) — those menu items are hidden
    /// for domain.
    @discardableResult
    func perform(accountKey: String, conversationKeys: [String], action: ConversationAction, cloud: CloudSession) async -> Bool {
        if AccountKey.isDomain(accountKey) {
            // An MX row's accountKey IS its org (`Conversation(cloud:orgId:)`), so act
            // against that org — not whichever one is current (a second org's rows in
            // the unified inbox / Lore were filed against the wrong org). A `dom_…`
            // key falls back to the current org.
            let orgId = accountKey.hasPrefix(AccountKey.domainPrefix) ? accountKey : nil
            // Single-thread mark-read uses its dedicated endpoint (targeted, vs
            // the bulk action path).
            if action == .markRead, conversationKeys.count == 1 {
                await cloud.markRead(conversationId: conversationKeys[0], read: true, orgId: orgId)
                await cloud.refreshUnreadCount()
                return true
            }
            guard let cloudAction = cloud.domainAction(for: action) else { return false }
            let ok = await cloud.perform(conversationIds: conversationKeys, action: cloudAction, orgId: orgId)
            // Recompute the domain unread count now so the badge tracks the action
            // (and undo) immediately, not on the next periodic refresh.
            if ok { await cloud.refreshUnreadCount() }
            return ok
        }
        return await perform(accountKey: accountKey, conversationKeys: conversationKeys, action: action.verb)
    }

    /// Compose + send a message through the engine's outbox (durable; retries on
    /// transient failure). Returns whether it was accepted and a human status
    /// ("sent" / "pending" / "failed"). Runs off the main thread.
    func send(accountKey: String, from: String, to: String, cc: String?, bcc: String?,
              subject: String?, bodyPlain: String, attachments: [FfiAttachment],
              replyToMessageKey: String? = nil) async -> (ok: Bool, status: String) {
        guard let engine else { return (false, "engine unavailable") }
        Log.action.info("send acct=\(accountKey, privacy: .public) to=\(to) cc=\(cc ?? "-") bcc=\(bcc ?? "-") atts=\(attachments.count)")
        let result: (Bool, String) = await Task.detached {
            do {
                let json = try engine.sendMessage(
                    accountKey: accountKey, fromAddress: from, toAddress: to,
                    ccAddress: cc, bccAddress: bcc, subject: subject,
                    bodyHtml: nil, bodyPlain: bodyPlain, attachments: attachments,
                    replyToMessageKey: replyToMessageKey
                )
                let status = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["status"] as? String ?? "queued"
                Log.action.info("send result: \(status, privacy: .public)")
                // Anything the outbox accepted (sent or queued) is a success from
                // the UI's view; only an outright failure status is an error.
                return (status != "failed", status)
            } catch {
                Log.action.error("send failed: \(String(describing: error), privacy: .public)")
                return (false, "\(error)")
            }
        }.value
        await MainActor.run { self.dataVersion += 1 }
        return result
    }

    /// Run `query` through each Gmail/Outlook account's own search (live; reads
    /// inside attachments) and return the local conversation keys it hit. An
    /// account that fails (offline, quota) adds nothing.
    func providerSearch(accountKey: String?, query: String) async -> [String] {
        guard let engine else { return [] }
        let searchable = Set(OAuthProvider.allCases.map(\.providerType))
        let keys = accounts.filter { searchable.contains($0.provider) && (accountKey == nil || $0.id == accountKey) }.map(\.id)
        return await withTaskGroup(of: [String].self) { group in
            for key in keys {
                group.addTask {
                    do {
                        let json = try engine.providerSearchJson(accountKey: key, query: query)
                        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
                    } catch {
                        Log.engine.error("providerSearch \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                        return []
                    }
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
    }

    /// Fetch a message's full body + attachment metadata from the provider (live).
    /// Used to list a message's attachments in the reader.
    func fetchMessage(accountKey: String, messageKey: String) async -> (bodyHtml: String?, bodyPlain: String?, attachments: [AttachmentInfo]) {
        guard let engine else { return (nil, nil, []) }
        return await Task.detached {
            do {
                let json = try engine.fetchMessage(accountKey: accountKey, messageKey: messageKey)
                guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return (nil, nil, []) }
                let atts = (obj["attachments"] as? [[String: Any]] ?? []).compactMap { a -> AttachmentInfo? in
                    guard let id = a["attachment_id"] as? String, let name = a["filename"] as? String else { return nil }
                    return AttachmentInfo(attachmentId: id, filename: name,
                                          mimeType: a["mime_type"] as? String ?? "application/octet-stream",
                                          size: (a["size"] as? Int) ?? 0)
                }
                Log.reader.info("fetchMessage \(messageKey, privacy: .public): \(atts.count) attachment(s)")
                return (obj["body_html"] as? String, obj["body_plain"] as? String, atts)
            } catch {
                Log.reader.error("fetchMessage failed: \(String(describing: error), privacy: .public)")
                return (nil, nil, [])
            }
        }.value
    }

    /// Download one attachment's bytes from the provider (live), cached in memory
    /// for the session so re-opening/forwarding/saving the same file doesn't
    /// re-download it. Returns nil on error.
    func downloadAttachment(accountKey: String, messageKey: String, attachmentId: String) async -> Data? {
        let cacheKey = "\(accountKey):\(messageKey):\(attachmentId)"
        if let cached = await attachmentCache.get(cacheKey) { return cached }

        // On-disk cache (survives app restart) — keyed by the full triple so two
        // files with the same name never collide.
        let diskURL = Self.attachmentCacheURL(cacheKey)
        if let diskData = try? Data(contentsOf: diskURL), !diskData.isEmpty {
            await attachmentCache.set(cacheKey, diskData)
            return diskData
        }

        guard let engine else { return nil }
        let data: Data? = await Task.detached {
            do {
                let bytes = try engine.downloadAttachment(accountKey: accountKey, messageKey: messageKey, attachmentId: attachmentId)
                Log.action.info("downloaded attachment \(attachmentId, privacy: .public): \(bytes.count) bytes")
                return bytes
            } catch {
                Log.action.error("downloadAttachment failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
        if let data {
            await attachmentCache.set(cacheKey, data)
            try? data.write(to: diskURL, options: .atomic) // persist for next session
        }
        return data
    }

    /// A suspended app sits on whatever it holds; the bytes are still on disk.
    func dropAttachmentMemory() {
        Task { await attachmentCache.removeAll() }
    }

    /// On-disk location for a cached attachment, under Caches/attachments. The
    /// triple key is sanitized to a safe filename.
    private static func attachmentCacheURL(_ key: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = key.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent(safe)
    }

    /// Session-scoped LRU cache of attachment bytes (files can be tens of MB, so
    /// only a handful are kept; oldest dropped first).
    private let attachmentCache = AttachmentByteCache()

    /// Add a connected account (after the native OAuth/IMAP flow obtained
    /// credentials) and kick its sync. Returns the new account key. Refreshes the
    /// account list + data version on success.
    func addAccount(providerType: String, email: String, displayName: String, authMethod: String,
                    accessToken: String? = nil, refreshToken: String? = nil, password: String? = nil,
                    host: String? = nil, port: UInt16? = nil, useTls: Bool? = nil,
                    smtpHost: String? = nil, smtpPort: UInt16? = nil, smtpUseTls: Bool? = nil,
                    cloudBackup: Bool? = nil) async -> (ok: Bool, value: String) {
        guard let engine else { return (false, "engine unavailable") }
        Log.engine.info("addAccount \(email) provider=\(providerType, privacy: .public)")
        let result: (Bool, String) = await Task.detached {
            do {
                let key = try engine.addAccount(
                    providerType: providerType, email: email, displayName: displayName,
                    authMethod: authMethod, accessToken: accessToken, refreshToken: refreshToken,
                    password: password, host: host, port: port, useTls: useTls,
                    smtpHost: smtpHost, smtpPort: smtpPort, smtpUseTls: smtpUseTls,
                    cloudBackup: cloudBackup)
                return (true, key)
            } catch {
                Log.engine.error("addAccount failed: \(String(describing: error), privacy: .public)")
                return (false, "\(error)")
            }
        }.value
        if result.0 {
            store.reopenIfNeeded()
            refreshAccounts()
            dataVersion += 1
        }
        return result
    }

    /// Add a Meta BYOK account (Instagram/Messenger/WhatsApp). The app secret +
    /// System User token are stored encrypted on-device; the engine validates the
    /// token, subscribes the app webhooks, and registers the relay in the
    /// background. Returns the new account key. See docs/Cloud-Push.md (Meta).
    func addMetaAccount(channel: String, displayName: String?, appId: String, appSecret: String,
                        systemUserToken: String, facebookPageId: String? = nil,
                        instagramAccountId: String? = nil, whatsappPhoneNumberId: String? = nil,
                        whatsappBusinessAccountId: String? = nil,
                        reuseCredentialsFrom: String? = nil,
                        cloudBackup: Bool? = nil) async -> (ok: Bool, value: String) {
        guard let engine else { return (false, "engine unavailable") }
        Log.engine.info("addMetaAccount channel=\(channel, privacy: .public)")
        let result: (Bool, String) = await Task.detached {
            do {
                let key = try engine.addMetaAccount(
                    channel: channel, displayName: displayName, appId: appId, appSecret: appSecret,
                    systemUserToken: systemUserToken, facebookPageId: facebookPageId,
                    instagramAccountId: instagramAccountId, whatsappPhoneNumberId: whatsappPhoneNumberId,
                    whatsappBusinessAccountId: whatsappBusinessAccountId,
                    reuseCredentialsFrom: reuseCredentialsFrom,
                    cloudBackup: cloudBackup)
                return (true, key)
            } catch {
                Log.engine.error("addMetaAccount failed: \(String(describing: error), privacy: .public)")
                return (false, "\(error)")
            }
        }.value
        if result.0 {
            store.reopenIfNeeded()
            refreshAccounts()
            dataVersion += 1
        }
        return result
    }

    // MARK: - Credential vault (zero-knowledge cloud backup — see docs/E2EE.md)

    /// Enable cloud backup with the inbox2 password (creates the vault + uploads
    /// existing backup-flagged accounts). Returns the vault id on success.
    func enableCloudBackup(password: String) async -> (ok: Bool, value: String) {
        guard let engine else { return (false, "engine unavailable") }
        return await Task.detached {
            do { return (true, try engine.enableCloudBackup(password: password)) }
            catch { return (false, "\(error)") }
        }.value
    }

    /// Unlock the vault on this device with the inbox2 password.
    func unlockVault(password: String) async -> Bool {
        guard let engine else { return false }
        return await Task.detached {
            do { try engine.unlockVault(password: password); return true } catch { return false }
        }.value
    }

    /// Re-encrypt all backed-up credentials under a new password (after a change).
    func rotateVault(newPassword: String) async -> Bool {
        guard let engine else { return false }
        return await Task.detached {
            do { try engine.rotateVault(newPassword: newPassword); return true } catch { return false }
        }.value
    }

    /// Restore all cloud-backed credentials with the inbox2 password (new device).
    /// Returns the count restored. Refreshes the account list on success.
    func restoreFromCloud(password: String) async -> (ok: Bool, count: UInt32) {
        guard let engine else { return (false, 0) }
        let result: (Bool, UInt32) = await Task.detached {
            do { return (true, try engine.restoreFromCloud(password: password)) }
            catch {
                Log.engine.error("restoreFromCloud failed: \(String(describing: error), privacy: .public)")
                return (false, 0)
            }
        }.value
        if result.0 {
            store.reopenIfNeeded()
            refreshAccounts()
            dataVersion += 1
        }
        return result
    }

    /// Drop the vault session (DEK + local state). Call on sign-out / account switch.
    func clearVaultSession() {
        engine?.clearVaultSession()
    }

    /// `{ enabled, unlocked, account_count }` JSON, or nil if unavailable.
    func vaultStatusJson() -> String? {
        guard let engine else { return nil }
        return try? engine.vaultStatusJson()
    }

    /// Remove a connected account and all its local data. Refreshes the account
    /// list + data version on success.
    func removeAccount(accountKey: String) async -> Bool {
        guard let engine else { return false }
        Log.engine.info("removeAccount \(accountKey, privacy: .public)")
        let ok = await Task.detached {
            do { try engine.removeAccount(accountKey: accountKey); return true }
            catch {
                Log.engine.error("removeAccount failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if ok {
            store.reopenIfNeeded()
            refreshAccounts()
            dataVersion += 1
        }
        return ok
    }

    /// Re-queue a failed outbox message for immediate delivery.
    func retryOutbox(accountKey: String, outboxKey: String) async -> Bool {
        guard let engine else { return false }
        Log.action.info("retryOutbox \(outboxKey, privacy: .public)")
        let ok = await Task.detached {
            do { try engine.retryOutbox(accountKey: accountKey, outboxKey: outboxKey); return true }
            catch {
                Log.action.error("retryOutbox failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if ok { await MainActor.run { self.dataVersion += 1 } }
        return ok
    }

    /// Cancel a queued/failed send by deleting its outbox entry.
    func deleteOutbox(accountKey: String, outboxKey: String) async -> Bool {
        guard let engine else { return false }
        Log.action.info("deleteOutbox \(outboxKey, privacy: .public)")
        let ok = await Task.detached {
            do { return try engine.deleteOutbox(accountKey: accountKey, outboxKey: outboxKey) }
            catch {
                Log.action.error("deleteOutbox failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if ok { await MainActor.run { self.dataVersion += 1 } }
        return ok
    }

    // MARK: - Bridge (shared Rust brief + agent)

    func bridgeBrief(_ config: FfiBridgeConfig) async -> FfiBridgeReply? {
        guard let engine else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do { return try engine.bridgeBrief(config: config) } catch {
                Log.engine.error("bridgeBrief failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    func bridgeTomorrow(_ config: FfiBridgeConfig) async -> FfiBridgeReply? {
        guard let engine else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do { return try engine.bridgeTomorrow(config: config) } catch {
                Log.engine.error("bridgeTomorrow failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    func bridgeWeekHighlights(_ config: FfiBridgeConfig) async -> FfiBridgeReply? {
        guard let engine else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do { return try engine.bridgeWeekHighlights(config: config) } catch {
                Log.engine.error("bridgeWeekHighlights failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    func bridgeReply(_ config: FfiBridgeConfig, transcript: String) async -> FfiBridgeReply? {
        guard let engine else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do { return try engine.bridgeReply(config: config, transcript: transcript) } catch {
                Log.engine.error("bridgeReply failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    /// Interpret a voice command → a confidence-scored action: speak, clarify, or a
    /// DRAFT (email/event) for the UI to put on screen. Never sends/saves.
    func bridgeCommand(_ config: FfiBridgeConfig, transcript: String) async -> FfiBridgeAction? {
        guard let engine else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do { return try engine.bridgeCommand(config: config, transcript: transcript) } catch {
                Log.engine.error("bridgeCommand failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    /// Spoken read-out of one thread (previous-message context + latest-message
    /// summary) — backs the email-detail audio button.
    func bridgeEmailVoice(_ config: FfiBridgeConfig, conversationKey: String) async -> FfiBridgeReply? {
        guard let engine else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do { return try engine.bridgeEmailVoice(config: config, conversationKey: conversationKey) } catch {
                Log.engine.error("bridgeEmailVoice failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    /// Re-run triage classification + summaries for ONE conversation with an explicit
    /// engine (the reader's "Process with") — the result is written with full model
    /// provenance (`triage_source`) and `triage-updated` fires. Returns the recorded
    /// source tag, or the error message on failure.
    func reprocessConversation(_ config: FfiBridgeConfig, conversationKey: String) async -> Result<String, FfiError> {
        guard let engine else { return .failure(.Engine("Still starting up. Try again in a moment.")) }
        return await Task.detached(priority: .userInitiated) {
            do { return .success(try engine.reprocessConversation(config: config, conversationKey: conversationKey)) }
            catch let e as FfiError { return .failure(e) }
            catch { return .failure(.Engine(error.localizedDescription)) }
        }.value
    }

    /// Clear the voice agent's running dialog memory — call when a fresh interaction
    /// begins (a new daily brief) or the user cancels.
    func bridgeResetDialog() {
        guard let engine else { return }
        Task.detached(priority: .utility) { engine.bridgeResetDialog() }
    }

    /// Pre-compose the daily brief into the core's cache so the next brief speaks
    /// instantly. Cheap when nothing changed. Driven by a timer while the app is active.
    func bridgeBriefPrewarm(_ config: FfiBridgeConfig) async {
        guard let engine else { return }
        await Task.detached(priority: .utility) {
            engine.bridgeBriefPrewarm(config: config)
        }.value
    }

    /// nil = valid; otherwise the OpenAI error message.
    func bridgeValidateOpenAI(_ key: String) async -> String? {
        guard let engine else { return "Still starting up. Try again in a moment." }
        return await Task.detached(priority: .userInitiated) {
            do { try engine.bridgeValidateOpenai(key: key); return nil }
            catch let FfiError.Engine(msg) { return msg }
            catch { return error.localizedDescription }
        }.value
    }

    /// OpenAI TTS bytes, or the error message. `voice` is the chosen tts-1 voice.
    func bridgeOpenAITTS(key: String, text: String, voice: String) async -> Result<Data, BridgeError> {
        guard let engine else { return .failure(BridgeError(message: "Still starting up. Try again in a moment.")) }
        return await Task.detached(priority: .userInitiated) {
            do { return .success(try engine.bridgeOpenaiTts(key: key, text: text, voice: voice)) }
            catch let FfiError.Engine(msg) { return .failure(BridgeError(message: msg)) }
            catch { return .failure(BridgeError(message: error.localizedDescription)) }
        }.value
    }

    /// OpenAI speech-to-text — transcribe WAV `audio`, or nil on failure.
    func bridgeOpenAITranscribe(key: String, audio: Data) async -> String? {
        guard let engine else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do { return try engine.bridgeOpenaiTranscribe(key: key, audio: audio) }
            catch {
                Log.engine.error("OpenAI transcribe failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    // MARK: - Bridge model manager (three-lane TTS / STT / NLU)

    /// The three lanes (native / free / openai) for a capability, with availability +
    /// download state. Cheap (disk stat only) — safe to call synchronously.
    func modelLanes(_ capability: String, hasKey: Bool) -> [FfiLaneInfo] {
        guard let engine else { return [] }
        return (try? engine.modelLanes(capability: capability, hasValidKey: hasKey)) ?? []
    }

    /// The lane the core will actually route to for `capability` given the user's
    /// preference: `native` | `free` | `openai` | `needs-download`.
    func effectiveLane(_ capability: String, pref: BridgeLane, hasKey: Bool) -> String {
        guard let engine else { return BridgeLane.native.rawValue }
        return (try? engine.effectiveLane(capability: capability, userPref: pref.rawValue, hasValidKey: hasKey))
            ?? BridgeLane.native.rawValue
    }

    // MARK: - Prompt templates (dev-mode editor)

    /// The persisted prompt-override file — mirrors desktop's `<data dir>/prompts.toml`.
    private var promptsFileURL: URL { dataDir.appendingPathComponent("prompts.toml") }

    /// Per-section view of the active prompt template: the persisted override's
    /// text where a section was edited, the embedded default otherwise.
    func promptSections() -> [FfiPromptSection] {
        guard let engine else { return [] }
        let stored = try? String(contentsOf: promptsFileURL, encoding: .utf8)
        // A stored file that no longer validates falls back to the defaults view
        // (it was also skipped at launch, so this matches what's running).
        return (try? engine.promptSections(tomlText: stored))
            ?? ((try? engine.promptSections(tomlText: nil)) ?? [])
    }

    /// The embedded default text per section key — the editor's reset targets
    /// and its "edited" detection.
    func defaultPromptSections() -> [String: String] {
        guard let engine, let sections = try? engine.promptSections(tomlText: nil) else { return [:] }
        return Dictionary(uniqueKeysWithValues: sections.map { ($0.key, $0.text) })
    }

    /// Build, validate, install, and persist a prompt override from the edited
    /// sections. Returns nil on success, the validation message otherwise — on
    /// error nothing changes (the running prompts and the file stay as they were).
    func applyPromptSections(_ sections: [FfiPromptSection]) -> String? {
        guard let engine else { return "Still starting up. Try again in a moment." }
        do {
            let toml = try engine.buildPromptOverrides(sections: sections)
            try engine.setPromptOverrides(tomlText: toml.isEmpty ? nil : toml)
            if toml.isEmpty {
                try? FileManager.default.removeItem(at: promptsFileURL)
            } else {
                try toml.write(to: promptsFileURL, atomically: true, encoding: .utf8)
            }
            return nil
        } catch let FfiError.Engine(msg) {
            return msg
        } catch {
            return error.localizedDescription
        }
    }

    private var didWarmVoice = false

    /// Preload the on-device neural TTS voice (Kokoro) once per launch, off the main
    /// thread, so the first Bridge brief speaks without the ~330 MB model-load pause.
    /// A no-op unless the resolved TTS lane is the free/Kokoro one with its model
    /// installed (the OpenAI/native lanes have nothing to preload), and only the first
    /// call does anything — subsequent calls and a racing first `speak` are guarded.
    func warmUpVoiceOnce(pref: BridgeLane, hasKey: Bool) {
        guard !didWarmVoice else { return }
        didWarmVoice = true
        guard effectiveLane("tts", pref: pref, hasKey: hasKey) == BridgeLane.free.rawValue,
              let dir = modelPath(BridgeModelIDs.kokoro) else { return }
        Task.detached(priority: .utility) {
            let ok = await KokoroCache.shared.warmup(modelDir: dir)
            Log.engine.info("Bridge voice warmup: \(ok ? "ready" : "unavailable", privacy: .public)")
        }
    }

    /// Start (or resume) downloading a free model. Returns immediately; progress
    /// arrives as `model-download` events → `modelDownloads`.
    func downloadModel(_ id: String) {
        guard let engine else { return }
        modelDownloads[id] = ModelDownload(id: id, state: "downloading", received: 0, total: 0, error: nil)
        do { try engine.modelDownload(id: id) }
        catch { Log.engine.error("modelDownload \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)") }
    }

    /// Delete a downloaded free model.
    func deleteModel(_ id: String) {
        guard let engine else { return }
        do { try engine.modelDelete(id: id) } catch {
            Log.engine.error("modelDelete(\(id, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
        }
        modelDownloads.removeValue(forKey: id)
    }

    /// The verified on-disk dir for an installed model (for the native engine), or nil.
    func modelPath(_ id: String) -> String? { engine?.modelPath(id: id) }

    /// The local rules, read off the main actor.
    func localRules() async -> [LocalRule] { await store.read { $0.localRules() } }

    // MARK: - Lore todos (email-less; `lore_todos` in the core)

    /// Open Lore todos, oldest first.
    func loreTodos() async -> [LoreTodo] {
        guard let engine else { return [] }
        return await Task.detached {
            guard let json = try? engine.loreListTodosJson() else { return [] }
            return (try? JSONDecoder().decode([LoreTodo].self, from: Data(json.utf8))) ?? []
        }.value
    }

    /// What the on-device ontology learned about an organization (by domain) or a
    /// person (by address) — exact match, like the web's `useLoreFacts`.
    func loreFacts(kind: String, domain: String?, address: String?) async -> [LoreFact] {
        guard let engine else { return [] }
        return await Task.detached {
            let q = kind == "organization" ? domain : address
            guard let json = try? engine.loreEntitiesJson(kind: kind, q: q),
                  let rows = try? JSONDecoder().decode(LoreEntitiesResponse.self, from: Data(json.utf8)).entities,
                  let hit = rows.first(where: { kind == "organization" ? $0.emailDomain == domain : $0.address == address }),
                  let detail = try? engine.loreEntityJson(id: hit.id) else { return [] }
            return (try? JSONDecoder().decode(LoreEntityResponse.self, from: Data(detail.utf8)).entity.facts) ?? []
        }.value
    }

    /// Add a todo from the "+ Add todo" row.
    func addLoreTodo(_ title: String) async -> Bool {
        guard let engine else { return false }
        let ok = await Task.detached { (try? engine.loreAddTodo(title: title)) != nil }.value
        if ok { await MainActor.run { self.dataVersion += 1 } }
        return ok
    }

    /// Tick a todo off (sets `done_at`).
    func completeLoreTodo(_ id: String) async {
        guard let engine else { return }
        _ = await Task.detached { try? engine.loreCompleteTodo(id: id) }.value
        await MainActor.run { self.dataVersion += 1 }
    }

    /// Toggle a local rule's enabled flag.
    func setRuleEnabled(ruleKey: String, enabled: Bool) async -> Bool {
        guard let engine else { return false }
        Log.action.info("setRuleEnabled \(ruleKey, privacy: .public) = \(enabled)")
        let ok = await Task.detached {
            do { return try engine.setRuleEnabled(ruleKey: ruleKey, enabled: enabled) }
            catch {
                Log.action.error("setRuleEnabled failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if ok { await MainActor.run { self.dataVersion += 1 } }
        return ok
    }

    /// Create a built-in local rule from JSON conditions + action. Returns the key.
    func createBuiltinRule(name: String, conditionsJSON: String, actionJSON: String,
                           accountKey: String?, enabled: Bool) async -> (ok: Bool, key: String) {
        guard let engine else { return (false, "") }
        Log.action.info("createBuiltinRule \(name)")
        let result: (Bool, String) = await Task.detached {
            do {
                let key = try engine.createBuiltinRule(name: name, conditionsJson: conditionsJSON,
                                                       actionJson: actionJSON, accountKey: accountKey, enabled: enabled)
                return (true, key)
            } catch {
                Log.action.error("createBuiltinRule failed: \(String(describing: error), privacy: .public)")
                return (false, "\(error)")
            }
        }.value
        if result.0 { await MainActor.run { self.dataVersion += 1 } }
        return result
    }

    /// Update a built-in rule's name + conditions + action.
    func updateBuiltinRule(ruleKey: String, name: String, conditionsJSON: String, actionJSON: String) async -> Bool {
        guard let engine else { return false }
        Log.action.info("updateBuiltinRule \(ruleKey, privacy: .public) \(name)")
        let ok = await Task.detached {
            do {
                return try engine.updateBuiltinRule(ruleKey: ruleKey, name: name,
                                                    conditionsJson: conditionsJSON, actionJson: actionJSON)
            } catch {
                Log.action.error("updateBuiltinRule failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if ok { await MainActor.run { self.dataVersion += 1 } }
        return ok
    }

    /// Delete a local rule by key.
    func deleteRule(ruleKey: String) async -> Bool {
        guard let engine else { return false }
        Log.action.info("deleteRule \(ruleKey, privacy: .public)")
        let ok = await Task.detached {
            do { return try engine.deleteRule(ruleKey: ruleKey) }
            catch {
                Log.action.error("deleteRule failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if ok { await MainActor.run { self.dataVersion += 1 } }
        return ok
    }

    /// Create a calendar event from a JSON `EventDraft`. Returns the provider id.
    func createCalendarEvent(accountKey: String, calendarProviderId: String, draftJSON: String) async -> (ok: Bool, value: String) {
        guard let engine else { return (false, "engine unavailable") }
        Log.action.info("createCalendarEvent acct=\(accountKey, privacy: .public) cal=\(calendarProviderId, privacy: .public)")
        let result: (Bool, String) = await Task.detached {
            do {
                let id = try engine.createCalendarEvent(accountKey: accountKey,
                                                        calendarProviderId: calendarProviderId, draftJson: draftJSON)
                return (true, id)
            } catch {
                Log.action.error("createCalendarEvent failed: \(String(describing: error), privacy: .public)")
                return (false, "\(error)")
            }
        }.value
        if result.0 { await MainActor.run { self.dataVersion += 1 } }
        return result
    }

    /// RSVP to an event by its local key. `response` is accepted | declined | tentative.
    /// Returns the provider error string on failure so the UI can surface it.
    func respondToEvent(accountKey: String, eventKey: String, response: String) async -> (ok: Bool, error: String) {
        guard let engine else { return (false, "engine unavailable") }
        Log.action.info("respondToEvent \(eventKey, privacy: .public) = \(response, privacy: .public)")
        let result: (Bool, String) = await Task.detached {
            do { try engine.respondToEvent(accountKey: accountKey, eventKey: eventKey, response: response); return (true, "") }
            catch {
                Log.action.error("respondToEvent failed: \(String(describing: error), privacy: .public)")
                return (false, "\(error)")
            }
        }.value
        if result.0 { await MainActor.run { self.dataVersion += 1 } }
        return result
    }

    // MARK: - Meeting invites (local channels — docs/Open-Tracking.md sibling)

    /// Resolve a meeting invite from a local-channel message's calendar (ICS)
    /// attachment. Returns nil when the attachment isn't a `REQUEST` invite. The FFI
    /// returns a JSON `ClientInvite` string (or nil).
    func inviteFor(accountKey: String, messageKey: String, attachmentId: String) async -> ClientInvite? {
        guard let engine else { return nil }
        return await Task.detached {
            do {
                guard let json = try engine.inviteForAttachment(accountKey: accountKey, messageKey: messageKey, attachmentId: attachmentId),
                      let data = json.data(using: .utf8) else { return nil }
                return try JSONDecoder().decode(ClientInvite.self, from: data)
            } catch {
                Log.reader.error("inviteFor failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    /// Add an emailed ICS event to the account's calendar (Google/Microsoft API, the
    /// account's primary writable calendar). Returns the local event key on success —
    /// empty means it was added but the resync hasn't landed the row yet.
    ///
    /// The device zone is passed for *floating* ICS times only; anything the ICS zoned
    /// itself keeps its own zone, so the hour can't drift.
    /// `value` is the event key when `ok`, and the engine's own error text when not —
    /// same shape as `createCalendarEvent`. The reason is shown in the banner, so a
    /// guessed one ("no writable calendar?") would send the user looking in the wrong place.
    func addInviteToCalendar(accountKey: String, messageKey: String, attachmentId: String) async -> (ok: Bool, value: String) {
        guard let engine else { return (false, "the engine isn't running") }
        let tz = TimeZone.current.identifier
        Log.action.info("addInviteToCalendar \(messageKey, privacy: .public) tz=\(tz, privacy: .public)")
        return await Task.detached {
            do {
                let key = try engine.addInviteToCalendar(accountKey: accountKey, messageKey: messageKey,
                                                         attachmentId: attachmentId,
                                                         calendarProviderId: nil, deviceTimezone: tz)
                return (true, key)
            } catch {
                let reason = Self.ffiReason(error)
                Log.action.error("addInviteToCalendar failed: \(reason, privacy: .public)")
                return (false, reason)
            }
        }.value
    }

    /// The meeting triage read out of a message body with no ICS attached, shaped as
    /// an invite (`detected`). Local SQLite only — cheap enough to ask on every open.
    func detectedInvite(accountKey: String, messageKey: String) async -> ClientInvite? {
        guard let engine else { return nil }
        return await Task.detached {
            do {
                guard let json = try engine.detectedInvite(accountKey: accountKey, messageKey: messageKey),
                      let data = json.data(using: .utf8) else { return nil }
                return try JSONDecoder().decode(ClientInvite.self, from: data)
            } catch {
                Log.reader.error("detectedInvite failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }.value
    }

    /// "Add to calendar" for a detected meeting; its floating time is read in the
    /// device zone. Same `(ok, value)` shape as `addInviteToCalendar`.
    func addDetectedMeetingToCalendar(accountKey: String, messageKey: String) async -> (ok: Bool, value: String) {
        guard let engine else { return (false, "the engine isn't running") }
        let tz = TimeZone.current.identifier
        return await Task.detached {
            do {
                let key = try engine.addDetectedMeetingToCalendar(accountKey: accountKey, messageKey: messageKey,
                                                                  calendarProviderId: nil, deviceTimezone: tz)
                return (true, key)
            } catch {
                let reason = Self.ffiReason(error)
                Log.action.error("addDetectedMeetingToCalendar failed: \(reason, privacy: .public)")
                return (false, reason)
            }
        }.value
    }

    /// Unwrap a UniFFI error to the message the core actually wrote, rather than the
    /// Swift enum's debug description. `nonisolated` so it can run on the detached
    /// task that made the call.
    nonisolated private static func ffiReason(_ error: Error) -> String {
        if case let FfiError.Engine(message) = error { return message }
        return String(describing: error)
    }

    /// RSVP to a local-channel meeting invite. `response` is accepted|declined|tentative.
    func respondToInvite(accountKey: String, messageKey: String, attachmentId: String, response: String) async -> Bool {
        guard let engine else { return false }
        Log.action.info("respondToInvite \(messageKey, privacy: .public) = \(response, privacy: .public)")
        let ok = await Task.detached {
            do { try engine.respondToInvite(accountKey: accountKey, messageKey: messageKey, attachmentId: attachmentId, response: response); return true }
            catch {
                Log.action.error("respondToInvite failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if ok { await MainActor.run { self.dataVersion += 1 } }
        return ok
    }

    /// Update an event by its local key from a JSON `EventDraft` (same shape as create).
    func updateCalendarEvent(accountKey: String, eventKey: String, draftJSON: String) async -> (ok: Bool, value: String) {
        guard let engine else { return (false, "engine unavailable") }
        Log.action.info("updateCalendarEvent acct=\(accountKey, privacy: .public) event=\(eventKey, privacy: .public)")
        let result: (Bool, String) = await Task.detached {
            do {
                try engine.updateCalendarEvent(accountKey: accountKey, eventKey: eventKey, draftJson: draftJSON)
                return (true, "")
            } catch {
                Log.action.error("updateCalendarEvent failed: \(String(describing: error), privacy: .public)")
                return (false, "\(error)")
            }
        }.value
        if result.0 { await MainActor.run { self.dataVersion += 1 } }
        return result
    }

    /// The rule of the series a synced instance belongs to, read off the
    /// provider (synced rows are expanded instances): `.success(nil)` for a
    /// one-off, `.failure` when it couldn't be read — the sheet must not then
    /// treat a series as a one-off.
    func calendarSeriesRule(accountKey: String, eventKey: String) async -> Result<String?, Error> {
        guard let engine else { return .failure(NSError(domain: "inbox2", code: 1, userInfo: [NSLocalizedDescriptionKey: "engine unavailable"])) }
        return await Task.detached {
            do { return .success(try engine.calendarSeriesRule(accountKey: accountKey, eventKey: eventKey)) }
            catch {
                Log.action.error("calendarSeriesRule failed: \(String(describing: error), privacy: .public)")
                return .failure(error)
            }
        }.value
    }

    /// Delete an event by its local key (provider write-through + local removal).
    /// Returns the provider error string on failure so the UI can surface it.
    func deleteCalendarEvent(accountKey: String, eventKey: String) async -> (ok: Bool, error: String) {
        guard let engine else { return (false, "engine unavailable") }
        Log.action.info("deleteCalendarEvent acct=\(accountKey, privacy: .public) event=\(eventKey, privacy: .public)")
        let result: (Bool, String) = await Task.detached {
            do { try engine.deleteCalendarEvent(accountKey: accountKey, eventKey: eventKey); return (true, "") }
            catch {
                Log.action.error("deleteCalendarEvent failed: \(String(describing: error), privacy: .public)")
                return (false, "\(error)")
            }
        }.value
        if result.0 { await MainActor.run { self.dataVersion += 1 } }
        return result
    }

    /// Someone else's meeting on this account's calendar — deleting it offers to
    /// decline to the organizer first (Google Calendar's "Send / Don't send").
    func isInvite(_ event: CalendarEvent) -> Bool {
        guard let organizer = event.organizerEmail?.lowercased(), !organizer.isEmpty else { return false }
        return organizer != accounts.first(where: { $0.id == event.accountKey })?.email.lowercased()
    }

    /// Delete, optionally declining first so the organizer hears about it — the
    /// delete alone tells nobody. A failed decline stops before the delete, so
    /// the event is still there to retry on.
    func deleteCalendarEvent(_ event: CalendarEvent, decline: Bool) async -> (ok: Bool, error: String) {
        if decline {
            let r = await respondToEvent(accountKey: event.accountKey, eventKey: event.id, response: "declined")
            if !r.ok { return (false, "Couldn't decline: \(r.error)") }
        }
        return await deleteCalendarEvent(accountKey: event.accountKey, eventKey: event.id)
    }

    /// Manual refresh: re-read accounts + bump the data version (pull-to-refresh).
    func reload() {
        store.reopenIfNeeded()
        refreshAccounts()
        dataVersion += 1
    }

    /// Kick a sync for one account (or all) off the main thread.
    func sync(accountKey: String? = nil) {
        guard let engine else { return }
        let keys = accountKey.map { [$0] } ?? accounts.map(\.id)
        guard !keys.isEmpty else { return }
        syncing = true
        scheduleSyncStop(after: 12)   // hard fallback if no events settle it
        for key in keys {
            Task.detached {
                do { try engine.startSync(accountKey: key) }
                catch { Log.sync.error("startSync \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)") }
            }
        }
    }

    /// Clear `syncing` after `seconds` of quiet; each sync event re-arms it.
    private func scheduleSyncStop(after seconds: Double) {
        syncSettle?.cancel()
        syncSettle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.syncing = false
        }
    }

    /// Recompute the offline-channel half of the app-icon badge from SQLite
    /// (all accounts, unread, inbox-visible). Cheap COUNT off the main thread.
    /// Fires on every data-changing engine event and after a background sync, so
    /// reading/deleting/syncing-away channel mail updates the badge promptly.
    func refreshChannelBadge() async {
        let n = await store.read { $0.unreadCount(accountKey: nil) }
        AppBadge.setChannelUnread(n)
        // Report to the API so a push that lands while the app is closed can
        // carry an accurate badge (domain unread + this device's channel unread).
        await PushRegistrar.reportChannelUnread(n)
    }

    /// Sync every account and await completion. Used by the background-refresh task:
    /// the core runs its rule scan after each sync and emits `new-message`, which our
    /// listener turns into a local notification — so we get push-like delivery while
    /// the app is backgrounded, with no APNs/Rails transport. Returns whether any
    /// account synced (so the BG task can report .newData vs .noData).
    func syncAllAndWait() async -> Bool {
        guard let engine else { return false }
        let keys = accounts.map(\.id)
        guard !keys.isEmpty else { return false }
        Log.sync.info("background sync starting for \(keys.count) account(s)")
        // `startSync` blocks until its account finishes and can't be cancelled, so a
        // slow account would hold the wake past the ~30 s iOS allows. Stop *waiting*
        // at 20 s, which leaves the callers time to finish; the sync carries on until
        // the process suspends and the next wake picks it up.
        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: continuation)
            let resumeOnce: @Sendable (Bool) -> Void = { completed in
                pending.withLock { current in
                    current?.resume(returning: completed)
                    current = nil
                }
            }
            Task.detached {
                await withTaskGroup(of: Void.self) { group in
                    for key in keys {
                        group.addTask {
                            do { try engine.startSync(accountKey: key) }
                            catch { Log.sync.error("bg sync \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)") }
                        }
                    }
                }
                resumeOnce(true)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(20))
                resumeOnce(false)
            }
        }
        await MainActor.run {
            self.store.reopenIfNeeded()
            self.dataVersion += 1
        }
        Log.sync.info("background sync \(completed ? "complete" : "stopped waiting at 20 s", privacy: .public)")
        return true
    }

    /// Ingest a buffered Meta webhook event (driven by a silent `meta_event` push):
    /// fetch the raw payload, verify the HMAC against the local app_secret,
    /// normalize, apply. Returns whether anything was applied. See docs/Cloud-Push.md.
    func ingestMetaEvent(eventKey: String) async -> Bool {
        guard let engine else { return false }
        let applied: Bool = await Task.detached {
            do { return try engine.ingestMetaEvent(eventKey: eventKey) }
            catch {
                Log.cloud.error("ingestMetaEvent failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
        if applied {
            await MainActor.run {
                self.store.reopenIfNeeded()
                self.dataVersion += 1
            }
        }
        return applied
    }
}

/// Bridges engine events to a Swift closure (UniFFI callback interface).
final class EngineListener: EngineEventListener {
    private let onEventCb: (String, String) -> Void
    init(_ onEvent: @escaping (String, String) -> Void) { self.onEventCb = onEvent }
    func onEvent(event: String, payloadJson: String) { onEventCb(event, payloadJson) }
}

/// A short error carrier for Bridge FFI calls (so a Result can carry the message).
struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Live state of a Bridge model download, parsed from a `model-download` event.
/// `state` ∈ absent | downloading | verifying | installing | installed | failed.
struct ModelDownload {
    let id: String
    let state: String
    let received: UInt64
    let total: UInt64
    let error: String?

    var isInstalled: Bool { state == "installed" }
    var isActive: Bool { ["downloading", "verifying", "installing"].contains(state) }
    /// 0…1 progress, or nil when the total isn't known yet.
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    init(id: String, state: String, received: UInt64, total: UInt64, error: String?) {
        self.id = id; self.state = state; self.received = received; self.total = total; self.error = error
    }

    init?(payloadJSON: String) {
        guard let data = payloadJSON.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["id"] as? String,
              let state = o["state"] as? String
        else { return nil }
        self.id = id
        self.state = state
        self.received = (o["received_bytes"] as? NSNumber)?.uint64Value ?? 0
        self.total = (o["total_bytes"] as? NSNumber)?.uint64Value ?? 0
        self.error = o["error"] as? String
    }
}

/// Account sync status values, mirrored from the core's `AccountStatus` — the
/// single source for the raw strings (CLAUDE.md: no duplicated enums).
enum AccountStatusValue {
    static let connected = "connected"
    static let connecting = "connecting"
    static let disconnected = "disconnected"
    static let error = "error"
    static let needsReauth = "needs_reauth"
}

/// A connected account, parsed resiliently from `list_accounts_json`.
struct AccountRow: Identifiable {
    let id: String
    let email: String
    let provider: String
    /// Account sync status — one of [`AccountStatusValue`]'s strings.
    let status: String
    /// Last sync failure reason from the core (`error_message`), when present.
    let errorMessage: String?
    /// Provider profile photo (e.g. googleusercontent), when the sync has one.
    let avatarURL: String?
    /// Meta accounts only: the (non-secret) Meta app id, so the UI can group
    /// channels by app and reuse credentials. `nil` for non-Meta accounts.
    var metaAppId: String? = nil

    /// Stored OAuth/credentials are dead — the user must re-authenticate. Sticky
    /// until reconnect succeeds; the UI shows a prominent Reconnect prompt.
    var needsReauth: Bool { status == AccountStatusValue.needsReauth }
    /// Any failed state (transient error or dead credentials).
    var isFailing: Bool { status == AccountStatusValue.error || needsReauth }

    static func parse(_ json: String) -> [AccountRow] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.map { o in
            let avatar = (o["avatar_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let err = (o["error_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let appId = (o["meta_app_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return AccountRow(
                id: (o["key"] as? String) ?? UUID().uuidString,
                email: (o["email_address"] as? String) ?? (o["display_name"] as? String) ?? "account",
                provider: "\(o["provider_type"] ?? "")",
                status: "\(o["status"] ?? "")",
                errorMessage: err,
                avatarURL: avatar,
                metaAppId: appId
            )
        }
    }
}
