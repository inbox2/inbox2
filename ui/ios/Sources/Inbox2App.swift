import SwiftUI
import UIKit
import BackgroundTasks

/// The Inbox2 iOS app. A native SwiftUI shell over the shared Rust core
/// (`InboxEngine`, via UniFFI) and the shared `@inbox2/email-body` JS (rendered in
/// a `WKWebView`). Dark is the default appearance; the theme follows the desktop
/// design tokens and can be switched System / Dark / Light.
/// App chrome coordination — lets pushed detail screens (e.g. the reader) hide the
/// floating bottom nav. A counter so overlapping detail screens balance correctly.
@MainActor final class ChromeModel: ObservableObject {
    @Published var detailScreens = 0
    /// Inbox multi-select swaps the floating nav for the bulk-action bar in the same
    /// spot, so the nav hides while editing (alongside pushed detail screens).
    @Published var editing = false
    /// Inbox search field is open — the nav hides so it doesn't cover results.
    @Published var searching = false
    /// Set by a reader address token's "Search mail" — the inbox pops to root,
    /// opens its search field with this query, then clears it.
    @Published var pendingSearch: String?
    /// Set by a meeting-invite banner tap — RootTabs switches to the Calendar tab
    /// and CalendarView opens this event's detail, then clears it.
    @Published var pendingCalendarEventKey: String?
    /// Set by the zone card's "Open calendar" (in-app or `inbox2://calendar` from the
    /// Live Activity) — RootTabs switches to the Calendar tab, then clears it.
    @Published var showCalendar = false
    /// The account the inbox is filtered to (nil = Unified), as a compose From key
    /// (a domain chip is its org id). New mail and new events default to it.
    @Published var inboxAccountKey: String?
    /// iPad calendar sidebar <-> CalendarView: the day the grid shows (CalendarView
    /// writes it, the mini month highlights it), a mini-month pick for the grid to
    /// jump to (consumed + cleared), and a New-event press (bumped per press).
    @Published var calendarDay = Date()
    @Published var calendarJump: Date?
    @Published var calendarCreateTick = 0
    @Published var calendarCanCreate = false
    var hideNav: Bool { detailScreens > 0 || editing || searching }
}

/// Tracks the cold-launch splash so screens underneath know when they're actually
/// visible. The onboarding hero waits on this before playing its spin — otherwise it
/// would animate hidden behind the splash and be finished before the user sees it.
@MainActor final class LaunchState: ObservableObject {
    @Published var splashFinished = false
}

/// Coordinates the app-wide read-aloud orb (`FloatingVoiceOrb`) — the standard shared orb,
/// centered ~⅓ down, shown on every surface while the `Speaker` is talking EXCEPT the
/// Bridge (which shows its own `OrbView`). `bridges` is a visibility counter (balanced
/// across tab switches); `readingConversationId` lets a reopened reader resume its playing
/// state for the thread still being spoken.
@MainActor final class VoicePresence: ObservableObject {
    @Published var bridges = 0
    @Published var readingConversationId: String?

    var bridgeVisible: Bool { bridges > 0 }
}

@main
struct Inbox2App: App {
    init() {
        HeldKeys.start()
        // Keep the extension's copy of the app-icon choice fresh. The extension
        // cannot read UIApplication.alternateIconName on its own.
        AppIconOption.syncSharedSelection()
        // Runs at process start — including background launches for a Live Activity
        // button / notification action, where no scene (and so no view `.task`) ever
        // appears. The handlers behind PushRegistrar need the engine right away.
        PushRegistrar.engine = EngineModel.shared
        PushRegistrar.cloud = CloudSession.shared
        // Same reason: a silent-push wake must be able to update the Live Activity
        // card after its sync, and adopt / report one Rails push-started.
        MailActivityManager.shared.startObserving()
    }

    // APNs registration + silent channel_sync push handling (docs/Cloud-Push.md).
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar
    @StateObject private var engine = EngineModel.shared
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var markRead = MarkReadManager()
    @StateObject private var drafts = DraftStore()
    @StateObject private var chrome = ChromeModel()
    @StateObject private var cloud = CloudSession.shared
    @StateObject private var privacy = PrivacyStore()
    @StateObject private var voice = VoiceEngineManager()
    @StateObject private var launch = LaunchState()
    // App-level so both the Bridge and the email-detail audio button share one
    // text-to-speech lane (one thing speaking at a time, one place to stop it).
    @StateObject private var speaker = Speaker()
    // Routes a voice command's draft (reply / meeting) onto a sheet for review.
    @StateObject private var bridgeRouter = BridgeRouter()
    // Drives the persistent floating read-aloud orb across screens.
    @StateObject private var voicePresence = VoicePresence()
    // Shared "read this mail aloud + offer to file it" flow — used by the reader's
    // speaker button and the inbox row's "Read aloud" action.
    @StateObject private var readAloud = ReadAloudController()
    @Environment(\.scenePhase) private var scenePhase
    /// Repeats while the app is active: pre-composes the daily brief so a Bridge tap
    /// speaks instantly. Cancelled when we leave the foreground.
    @State private var briefPrewarmTask: Task<Void, Never>?
    /// Throttles the return-to-foreground sync (see the `.active` case).
    @State private var lastForegroundSync = Date.distantPast

    /// BGAppRefresh identifier — must match Info.plist `BGTaskSchedulerPermittedIdentifiers`.
    static let refreshTaskId = "com.inbox2.refresh"

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environmentObject(engine)
                .environmentObject(themeManager)
                .environmentObject(markRead)
                .environmentObject(drafts)
                .environmentObject(chrome)
                .environmentObject(cloud)
                .environmentObject(privacy)
                .environmentObject(voice)
                .environmentObject(launch)
                .environmentObject(speaker)
                .environmentObject(bridgeRouter)
                .environmentObject(voicePresence)
                .environmentObject(readAloud)
                // Mirror the From-identity list + domain token so the "Send to Inbox2"
                // share extension can compose; pick up any sends it queued for us.
                .task {
                    ShareSync.writeContext(engine: engine, cloud: cloud)
                    await ShareSync.drain(engine: engine, cloud: cloud)
                    // Notification-button actions taken while the process was dead.
                    await NotificationManager.shared.drainPendingActions()
                    // Mail Live Activity: adopt push-started cards, report ActivityKit
                    // tokens, and put the newest unread on the lock screen.
                    MailActivityManager.shared.startObserving()
                    await MailActivityManager.shared.refresh()
                }
                // Card tap (inbox2://conversation/<key>) opens the thread; the inbox
                // consumes pendingConversationKey exactly like a notification tap.
                .onOpenURL { url in
                    guard url.scheme == "inbox2" else { return }
                    if url.host() == "conversation", !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" {
                        NotificationManager.shared.pendingConversationKey = url.lastPathComponent
                    } else if url.host() == "calendar" {
                        chrome.showCalendar = true
                    }
                }
                // Mirror cloud-synced per-channel open-tracking config into the local
                // engine at launch (re-fires when sign-in settles or the account list
                // loads) — async, so it never blocks startup (docs/Open-Tracking.md).
                .task(id: "\(cloud.state)-\(engine.accounts.count)") {
                    await engine.mirrorChannelTracking(cloud: cloud)
                }
                // Queue the next background refresh whenever we leave the foreground.
                // On return to foreground, re-evaluate device capabilities so the
                // On-device AI lane reflects Apple Intelligence becoming ready/enabled
                // after launch, rather than the cold-boot snapshot.
                // Hand the silent-push handler its engine (weak static — the
                // delegate is created by UIKit before the StateObjects exist).
                .task {
                    KokoroCache.armMemoryPressureUnload()
                    PushRegistrar.engine = engine
                    PushRegistrar.cloud = cloud
                    // Bridge the shared objects to the CarPlay scene (created by UIKit,
                    // outside the SwiftUI environment — same weak-static pattern).
                    CarPlayLink.engine = engine
                    CarPlayLink.voice = voice
                    CarPlayLink.speaker = speaker
                    CarPlayLink.router = bridgeRouter
                }
                // Jev triage metadata from the org: label names for MX rows + the
                // classifiable Spaces pushed to the engine (sign-in / org switch;
                // foreground re-runs it below).
                .task(id: "\(cloud.isSignedIn)|\(cloud.currentOrgId ?? "")") { await cloud.syncTriageMeta() }
                // Calendar zones: pull the near window and arm their alerts on sign-in
                // (and clear them all on sign-out). Foreground re-runs it below.
                .task(id: cloud.isSignedIn) { await ZoneStore.shared.refresh() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        // Gate on-device model LOADS off (the background triage worker
                        // then defers ambiguous threads / uses OpenAI instead of cold-
                        // loading ~1 GB) and free the resident model — a suspended app
                        // holding it was the dominant jetsam trigger in the field.
                        AppActivity.isForeground = false
                        Self.scheduleAppRefresh()
                        briefPrewarmTask?.cancel(); briefPrewarmTask = nil
                        // Off the main thread: unload() waits on the lock held for a
                        // whole model build, and a blocked main thread here is a
                        // watchdog kill.
                        DispatchQueue.global(qos: .userInitiated).async { LiteRTEngine.shared.unload() }
                        // Same reason as the LLM: the Kokoro TTS engine is ~330 MB and
                        // was never released once loaded, so a suspended app sat on it.
                        Task { await KokoroCache.shared.unload() }
                        engine.dropAttachmentMemory()
                    case .active:
                        AppActivity.isForeground = true
                        // Re-pin the appearance on the actual windows (they don't
                        // exist at init) so switcher snapshots keep the theme.
                        themeManager.syncWindowOverride()
                        // Refresh the share-extension context and flush any sends it queued
                        // (connected-channel mail it couldn't deliver from its sandbox).
                        ShareSync.writeContext(engine: engine, cloud: cloud)
                        Task { await ShareSync.drain(engine: engine, cloud: cloud) }
                        engine.refreshDeviceProfile()
                        startBriefPrewarm()
                        // Completes a push registration deferred for lack of a bearer
                        // (no-op once registered).
                        Task { await PushRegistrar.ensureRegistered() }
                        // Foreground is the only time iOS lets us START a card.
                        Task { await MailActivityManager.shared.refresh() }
                        // Resync the app-icon badge to the live unread count and
                        // drop any notification for mail already read/dealt-with.
                        Task { await engine.refreshChannelBadge() }
                        Task { await cloud.refreshUnreadCount() }
                        // Re-pull /account so a domain added/removed elsewhere shows
                        // up without a relaunch (no realtime channel on mobile).
                        Task { await cloud.refreshAccount(); await cloud.syncTriageMeta() }
                        Task { await PushRegistrar.reconcileDeliveredNotifications(engine: engine) }
                        // A backgrounded app doesn't sync — BGAppRefresh is opportunistic
                        // and often never fires — so returning to it showed mail that had
                        // been deleted/read on another device until you pulled to refresh.
                        // Re-sync the local channels and re-query the domain lists (nothing
                        // local changed, so `revision` wouldn't bump on its own).
                        // ponytail: fixed 60s throttle, not a real last-sync timestamp —
                        // app-flipping must not hammer Gmail (403s on its per-minute quota).
                        if Date().timeIntervalSince(lastForegroundSync) > 60 {
                            lastForegroundSync = Date()
                            engine.sync()
                            cloud.revision += 1
                        }
                        // Re-arm the pre-scheduled meeting alarms against the current
                        // calendar (moved/cancelled meetings, and the next ones past
                        // the 32-deep window we keep pending).
                        Task { await MeetingAlarms.shared.reconcile(engine: engine, force: true) }
                        // Zones edited elsewhere + the only moment iOS lets us start
                        // the zone Live Activity.
                        Task { await ZoneStore.shared.refresh() }
                    case .inactive:
                        // Pin the resolved appearance before iOS renders the
                        // app-switcher snapshots (see freezeWindowStyle docs).
                        themeManager.freezeWindowStyle()
                        briefPrewarmTask?.cancel(); briefPrewarmTask = nil
                    @unknown default: break
                    }
                }
                // Keep the app-icon badge live with the unread count. `dataVersion`
                // bumps on every local change too (mark-read/archive/trash via the
                // engine), not just sync events — so reading mail in-app updates the
                // badge immediately, without waiting for the next sync or foreground.
                .onChange(of: engine.dataVersion) { _, _ in
                    Task { await engine.refreshChannelBadge() }
                    // Calendar changes land in the same bump (`calendar-changed`), so
                    // a meeting created/moved/deleted while we're open re-arms its
                    // alarm. Self-throttled — this fires on mark-read too.
                    Task { await MeetingAlarms.shared.reconcile(engine: engine) }
                }
                .onChange(of: cloud.revision) { _, _ in
                    Task { await cloud.refreshUnreadCount() }
                }
        }
        // No APNs: instead, iOS periodically wakes us for a background refresh. We
        // sync all accounts; the core's post-sync rule scan emits `new-message`,
        // which becomes a local notification — push-like delivery, zero server infra.
        .backgroundTask(.appRefresh(Self.refreshTaskId)) {
            _ = await engine.syncAllAndWait()
            // Deliver any share-extension sends queued while the app was closed.
            await ShareSync.drain(engine: engine, cloud: cloud)
            // Both halves: refreshChannelBadge re-applies channel + last-known
            // domain, so a stale domain count would clobber a server-pushed badge.
            await cloud.refreshUnreadCount()
            await engine.refreshChannelBadge()
            // The alarms themselves don't need us awake — but this is the only
            // chance to notice a meeting that moved while the app was closed.
            await MeetingAlarms.shared.reconcile(engine: engine, force: true)
            await Self.scheduleAppRefresh()
        }
    }

    /// Pre-compose the daily brief now and every 30s while the app stays active, so the
    /// Bridge "speak my day" tap is instant. The core skips the (LLM) compose when the
    /// inbox is unchanged, so a quiet inbox costs ~one compose, not one every 30s.
    @MainActor private func startBriefPrewarm() {
        briefPrewarmTask?.cancel()
        briefPrewarmTask = Task { @MainActor in
            while !Task.isCancelled {
                // Match the tap's verbosity so the pre-warmed text is a cache hit.
                await engine.bridgeBriefPrewarm(voice.bridgeConfig(engine: engine, concise: !voice.effectiveCarMode))
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Ask iOS to wake us again (best-effort; the system decides the actual cadence).
    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.engine.info("scheduled background refresh")
        } catch {
            Log.engine.error("schedule background refresh failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Resolves the active Theme from the user's appearance preference (+ the system
/// scheme when set to System), injects it into the environment, and pins the
/// color scheme so native chrome matches.
struct ThemedRoot: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var launch: LaunchState
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    // Cold-launch splash. `@State` is created once per process launch, so the
    // splash shows on cold start and never again while the app stays alive.
    @State private var showSplash = true
    /// Don't build the UI until the scene is actually on screen. A silent
    /// `channel_sync` push or BGAppRefresh connects the window scene in the
    /// BACKGROUND, where the window has no geometry: SwiftUI then lays the whole
    /// tree out against a size-less proposal, every view falls back to its ideal
    /// width, and that layout never recovers — the app comes forward as a 22pt-wide
    /// column (the load spinner's own width) down the middle of a black screen.
    /// Deferring the build to the first `.active` also stops the launch splash from
    /// playing out — and finishing — while nobody is looking.
    @State private var built = false

    var body: some View {
        let theme = themeManager.theme(systemScheme: systemScheme)
        Group {
            if built {
                RootTabs()
                    .overlay {
                        if showSplash {
                            LaunchSplash {
                                showSplash = false
                                launch.splashFinished = true
                            }
                            .transition(.identity)
                            .zIndex(100)
                        }
                    }
            } else {
                theme.palette.bgBase.ignoresSafeArea()
            }
        }
        .environment(\.theme, theme)
        .tint(theme.palette.accentViolet)
        .preferredColorScheme(themeManager.preferredColorScheme)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { built = true }
        }
    }
}

struct RootTabs: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var chrome: ChromeModel
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    @EnvironmentObject private var voice: VoiceEngineManager
    @EnvironmentObject private var bridgeRouter: BridgeRouter
    @EnvironmentObject private var voicePresence: VoicePresence
    @EnvironmentObject private var launch: LaunchState
    /// Regular width (iPad full screen / wide split) gets the desktop-style IPadShell.
    @Environment(\.horizontalSizeClass) private var sizeClass
    // Notification taps land here (singleton, set by the UNUserNotificationCenter
    // delegate) — observed so a tap can pull the app onto the Inbox tab.
    @ObservedObject private var notifications = NotificationManager.shared
    @State private var selection = 0
    @State private var showCompose = false
    @State private var showFolders = false
    @State private var selectedFolder = MailFolder.inbox
    /// Active account's provider type (lifted from InboxListView) so the folder
    /// drawer can show Meta channel sub-views vs mailboxes.
    @State private var activeProvider: String?
    /// Account being re-authenticated from the needs-reauth alert (mirrors the
    /// Settings reconnect flow). Non-nil presents the OAuth/IMAP reconnect sheet.
    @State private var reconnectTarget: AccountRow?

    /// Map an account's provider type back to its OAuth provider so reconnect can
    /// pre-select it (nil for IMAP / unknown).
    private func oauthProvider(for acct: AccountRow) -> OAuthProvider? {
        OAuthProvider.allCases.first { $0.providerType == acct.provider }
    }

    /// Changes whenever the NLU lane, free-model variant, or OpenAI key changes, so
    /// the `.task(id:)` re-pushes the AI config to the triage worker.
    private var aiConfigKey: String { "\(voice.nluPref.rawValue)|\(voice.freeNluModel)|\(voice.canUseOpenAI)" }

    // Compose sits in the middle of the bar (added by FloatingNavBar); the four
    // tabs split two-and-two around it.
    private let navItems = [
        (icon: "tray.full", label: "Inbox"),
        (icon: "checklist", label: "Lore"),
        (icon: "calendar", label: "Calendar"),
        (icon: "gearshape", label: "Settings"),
    ]

    var body: some View {
        // INBOX2_SCREEN=reader opens straight into the WebView reader (for
        // capturing the shared email-body rendering without a tap).
        if ProcessInfo.processInfo.environment["INBOX2_SCREEN"] == "reader" {
            NavigationStack {
                ReaderView(html: SampleEmail.html)
                    .navigationTitle("Re: Q3 pipeline")
                    .navigationBarTitleDisplayMode(.inline)
            }
        } else if engine.accounts.isEmpty && !cloud.isSignedIn {
            // Fresh install: no connected mailbox and no signed-in domain → there's
            // nothing to scope the inbox to, so onboard instead of showing the tabs.
            // Adding an account (or signing in) repopulates `engine.accounts` and this
            // view swaps to the tabs automatically.
            OnboardingView()
                .background(theme.palette.bgBase.ignoresSafeArea())
        } else {
            ZStack(alignment: .bottom) {
                // Compile the orb Metal pipeline at launch so the first Bridge open
                // is instant (renders one invisible 2pt frame, then idle).
                OrbWarmup()
                if sizeClass == .regular {
                    IPadShell(selection: $selection, selectedFolder: $selectedFolder,
                              activeProvider: $activeProvider, onCompose: { showCompose = true })
                } else {
                Group {
                    switch selection {
                    case 0: InboxListView(selectedFolder: $selectedFolder, showFolders: $showFolders, activeProvider: $activeProvider)
                    case 1: LoreView()
                    case 2: CalendarView()
                    default: SettingsView()
                    }
                }
                if !chrome.hideNav {
                    FloatingNavBar(selection: $selection, items: navItems, onCompose: { showCompose = true })
                        .padding(.bottom, Space.s2)
                        // Pin to the screen bottom, never the keyboard: re-inserting on
                        // back while a dismissing keyboard's inset was still stale left
                        // the bar floating mid-screen. Full-height frame so the ignored
                        // inset extends the frame downward rather than centering the bar.
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: chrome.hideNav)
            // The Bridge shows its own OrbView, so the floating read-aloud orb is
            // suppressed while it is up — Lore's mic sheet sets `voicePresence.bridges`.
            // Keep the background triage worker on the same AI model the user picked
            // for the Bridge. Re-pushed on launch and whenever the lane/key changes.
            .task(id: aiConfigKey) { engine.setAiConfig(voice.bridgeConfig(engine: engine)) }
            // A tapped new-mail notification: surface the Inbox tab and drop any
            // covering sheets; the inbox itself consumes the key and pushes the thread.
            .onChange(of: notifications.pendingConversationKey) { _, key in
                guard key != nil else { return }
                selection = 0
                showCompose = false
                showFolders = false
            }
            // A meeting-invite banner tap → jump to the Calendar tab (CalendarView
            // consumes the key to open the event's detail).
            .onChange(of: chrome.pendingCalendarEventKey) { _, key in
                if key != nil { selection = 2 }
            }
            .onChange(of: chrome.showCalendar, initial: true) { _, on in
                guard on else { return }
                selection = 2
                chrome.showCalendar = false
                showCompose = false
                showFolders = false
            }
            // A tapped meeting alarm routes through the same key. `initial: true`
            // because a cold-launch tap sets it before this view exists.
            .onChange(of: notifications.pendingEventKey, initial: true) { _, key in
                guard let key else { return }
                chrome.pendingCalendarEventKey = key
                notifications.pendingEventKey = nil
                showCompose = false
                showFolders = false
            }
            .background(theme.palette.bgBase.ignoresSafeArea())
            // "You're in the zone" — above every tab while a notify-zone runs.
            .safeAreaInset(edge: .top, spacing: 0) { ZoneBanner() }
            .overlay {
                if showFolders {
                    FolderDrawer(isPresented: $showFolders, selection: $selectedFolder, provider: activeProvider)
                        .zIndex(10)
                }
            }
            // Persistent read-aloud orb: floats over every screen while speech outlives
            // the Bridge / reader that started it; tap to stop. Above the nav and drawer.
            .overlay { FloatingVoiceOrb().zIndex(20) }
            .sheet(isPresented: $showCompose) { ComposeView() }
            // Drafts surfaced by the Bridge voice agent — never sent/saved until the
            // user taps Send / Add on these sheets.
            // While Lore's Bridge sheet is up it presents these itself (a second sheet
            // can't come from here over it).
            .sheet(item: voicePresence.bridgeVisible ? .constant(nil) : $bridgeRouter.pendingCompose) { draft in ComposeView(draft: draft) }
            .sheet(item: voicePresence.bridgeVisible ? .constant(nil) : $bridgeRouter.pendingEvent) { seed in NewEventSheet(seed: seed) }
            // One-time prompt when an account's sign-in expires, so the user
            // learns about it even if they're not in Settings. "Reconnect" opens
            // the same OAuth/IMAP reconnect flow as the Settings banner. Held
            // back while the launch splash is up and off the Inbox tab (Settings
            // has its own banner), so it never pops over the loading screen.
            .alert("Account needs reconnecting", isPresented: Binding(
                get: { engine.reauthPrompt != nil && launch.splashFinished && selection == 0 },
                set: { if !$0 { engine.reauthPrompt = nil } }
            ), presenting: engine.reauthPrompt) { acct in
                Button("Reconnect") {
                    engine.reauthPrompt = nil
                    reconnectTarget = acct
                }
                Button("Later", role: .cancel) { engine.reauthPrompt = nil }
            } message: { acct in
                Text("Your sign-in for \(acct.email) expired. Reconnect to get new mail again.")
            }
            .sheet(item: $reconnectTarget) { acct in
                AddAccountView(reauth: oauthProvider(for: acct),
                               reauthIMAP: oauthProvider(for: acct) == nil,
                               reauthEmail: acct.email)
            }
        }
    }
}

/// Restores the native interactive swipe-right-to-go-back gesture on pushed detail
/// screens. SwiftUI disables its edge-swipe whenever a view hides the system back
/// button (`.navigationBarBackButtonHidden(true)` — e.g. MessageView's custom
/// chevron). Re-pointing the interactive pop recognizer's delegate back at the
/// navigation controller brings the real interactive transition back (live tracking,
/// previous screen sliding in), only when there's something to pop to.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
