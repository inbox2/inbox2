import SwiftUI

/// The Inbox tab — channels row, pill filters, themed conversation list with
/// search, swipe actions + a full-width undo toast, and an empty state. Rows open
/// the shared-JS WebView reader. Mock content until the SQLite read layer lands.
/// Drives the title collapse from the scroll offset (iOS 18+); on older systems
/// the header simply doesn't collapse.
private struct CollapseOnScroll: ViewModifier {
    @Binding var collapsed: Bool
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geo in
                // Normalize against the top inset so rest == 0 regardless of safe
                // area; collapse as soon as the big title starts leaving.
                (geo.contentOffset.y + geo.contentInsets.top) > 12
            } action: { _, c in
                if c != collapsed { withAnimation(.easeInOut(duration: 0.2)) { collapsed = c } }
            }
        } else {
            content
        }
    }
}

struct InboxListView: View {
    @Environment(\.theme) private var theme
    // Notification-tap navigation must wait until the app is fully foregrounded —
    // see the `.task` that consumes `pendingConversationKey` for why.
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    @EnvironmentObject private var chrome: ChromeModel
    @EnvironmentObject private var presence: VoicePresence
    @EnvironmentObject private var voice: VoiceEngineManager
    @EnvironmentObject private var speaker: Speaker
    // Shared read-aloud + voice-triage flow, driven in place from the row's "Read aloud".
    @EnvironmentObject private var readAloud: ReadAloudController
    // Notification taps: holds the tapped conversation key until consumed below.
    @ObservedObject private var notifications = NotificationManager.shared
    /// An MX domain chip's address folders: which one is open, and the trees that
    /// decide what its Inbox shows.
    @ObservedObject private var addressFolders = AddressFolderStore.shared
    /// Bumped to force a domain (API) re-query — domain mail has no engine event.
    @State private var cloudRefresh = 0
    /// Live text in the search field (every keystroke).
    @State private var query = ""
    /// Debounced + min-length-gated search term actually applied to the read. Empty
    /// while the user is typing fewer than `Self.minSearchChars` characters, so short
    /// fragments don't trigger an expensive full-store scan on every key.
    @State private var effectiveQuery = ""
    /// A search read is in flight (covers the debounce wait + the fetch) — drives the
    /// spinner in the search field.
    @State private var searching = false
    /// Shift / Command held on a hardware keyboard: a tap selects instead of opening.
    private var heldKeys: EventModifiers { HeldKeys.current }
    /// Pending debounce; cancelled and replaced on each keystroke.
    @State private var searchDebounce: Task<Void, Never>?
    @State private var filter = "All"
    @State private var selectedChannel = "unified"
    @Binding var selectedFolder: MailFolder
    @Binding var showFolders: Bool
    /// The active account's provider type, lifted so the folder drawer (owned by
    /// the app shell) can show Meta channel sub-views vs mailboxes.
    @Binding var activeProvider: String?
    /// iPad split layout: threads open in the shell's reader column instead of
    /// pushing onto this stack. nil on iPhone.
    var split: SplitReader? = nil
    /// The thread open in that column (passed by value so the row highlight re-renders).
    var splitSelectedId: String? = nil
    /// iPad portrait: back to the folder page of the sidebar stack this list sits in.
    var onBack: (() -> Void)? = nil
    /// iPad landscape with the folder column hidden: brings it back.
    var onShowFolders: (() -> Void)? = nil
    /// iPad landscape middle column: no status-bar items sit above it (the clock is
    /// over the sidebar), so the header rises into that strip.
    var underStatusBar = false
    /// This list instance, for `SplitReader.owner`.
    @State private var listId = UUID()
    /// Undo toast (banner + swipe-drag offset + reversing write-back) lives here.
    @StateObject private var undoController = InboxUndoController()
    /// Loaded rows + the reads that fill them (channel / domain / unified / outbox).
    @StateObject private var loader = InboxLoader()
    /// Edit mode, the selection set, bulk + single-row optimistic actions and undo.
    @StateObject private var bulk = InboxBulkController()
    @State private var navPath = NavigationPath()
    /// Non-nil while a thread-open push is in flight; collapses the row's two tap
    /// targets (and queued taps) into a single push. Cleared back at the list root.
    @State private var openGuardId: String?
    @State private var collapsed = false
    @State private var syncSpin = 0.0
    @State private var showSearch = false
    @State private var showActivity = false
    @FocusState private var searchFocused: Bool
    @State private var composeDraft: ComposeDraft?
    /// The conversation whose Forward is currently downloading attachments before
    /// the composer opens (drives the "Preparing…" menu label).
    @State private var preparingForwardId: String?
    @EnvironmentObject private var draftStore: DraftStore

    private var p: ThemePalette { theme.palette }

    /// The floating nav's Inbox-tab accent — reused for the bulk-bar icons and the
    /// `glowCapsule` chrome so the bar reads as the nav's sibling (single source).
    private let navIconColors = GlowCapsule.inboxAccent

    /// nil = unified (all accounts); else the selected account key.
    private var activeAccountKey: String? {
        selectedChannel == "unified" ? nil : selectedChannel
    }

    /// Drives the notification-tap navigation `.task`. Folds the pending key together
    /// with whether the app is active so the task re-fires when the scene becomes
    /// active (a background notification tap sets the key before that happens), and
    /// with whether the stack is at root so it re-fires once the pop below lands.
    private var notificationNavTrigger: String {
        "\(notifications.pendingConversationKey ?? "")|\(scenePhase == .active)|\(navPath.isEmpty)"
    }

    /// True when the active channel is the inbox2 domain (API-backed), vs an offline
    /// channel. Domain conversations route reads/actions through `cloud`.
    private var isDomainChannel: Bool { AccountKey.isDomain(activeAccountKey) }

    /// The "Move to Inbox" action for the current folder (Archive → unarchive,
    /// Trash → untrash), or nil for normal folders. Drives the bulk Inbox button.
    private var folderRestoreAction: ConversationAction? {
        switch selectedFolder {
        case .archive: return .unarchive
        case .spam: return .unspam
        case .trash: return .untrash
        default: return nil
        }
    }

    /// The store-side filter mapped from the pill string (single source of truth).
    private var activeFilter: InboxFilter { InboxFilter(rawValue: filter) ?? .all }

    /// The pill set for the active channel: unified pools both sources, so only the
    /// universal All/Unread pills apply (triage quadrants + team views need a specific
    /// chip); a domain chip shows its saved team views; an offline chip its filters.
    /// All sourced from existing constants — no string duplication.
    private var filterOptions: [String] {
        if activeAccountKey == nil { return [InboxFilter.all.rawValue, InboxFilter.unread.rawValue] }
        return isDomainChannel ? CloudSession.views : InboxFilter.allCases.map(\.rawValue)
    }

    /// Minimum characters before a typed query hits the store. Shorter fragments
    /// match nearly everything and make the type-to-search scan crawl.
    private static let minSearchChars = 3
    /// Idle time after the last keystroke before the search fires.
    private static let searchDebounceDelay: Duration = .milliseconds(280)

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The typed fragment is below the min-chars gate, so no search will run for it.
    private var searchTooShort: Bool { !trimmedQuery.isEmpty && trimmedQuery.count < Self.minSearchChars }
    /// Text sits in the search field but no search result set is on screen yet —
    /// either the fragment is too short to run, or the first debounce/fetch is
    /// still in flight. The list must not show the normal inbox in this state.
    private var searchPending: Bool { !trimmedQuery.isEmpty && effectiveQuery.isEmpty }

    /// Re-query whenever the channel, filter, search term, or engine data version
    /// changes (the latter fires on sync / new-message events). Keyed on the debounced
    /// `effectiveQuery`, not the live `query`, so each keystroke doesn't re-read.
    private var reloadKey: String { "\(selectedChannel)|\(selectedFolder.rawValue)|\(filter)|\(effectiveQuery)|\(engine.dataVersion)|\(cloud.currentOrgId ?? "-")|\(cloudRefresh)|\(cloud.revision)|\(addressFolders.selected ?? "")|\(addressFolders.version)" }

    /// Unified first, then one channel per connected account (email-labeled, with
    /// the provider's brand icon). With no accounts and no signed-in domain the
    /// app shows onboarding instead of this view, so the list is never empty here.
    private var channels: [Channel] {
        let unified = Channel(id: "unified", label: "Unified", initials: "", logoAsset: "ch-unified", seed: 0, online: true)
        let accountChannels = engine.accounts.enumerated().map { i, acct in
            Channel(
                id: acct.id,
                label: Channel.displayLabel(forEmail: acct.email),
                initials: MailAddress.initials(acct.email),
                logoAsset: Self.logoAsset(for: acct.provider),
                avatarURL: acct.avatarURL,
                seed: i + 1,
                online: acct.status == AccountStatusValue.connected
            )
        }
        // The signed-in inbox2 team pool appears as one chip PER domain — an org
        // owns many equal domains — mirroring the web per-domain workspace tabs.
        // Each chip is keyed by the domain's `dom_…` public id (the list filter);
        // the icon precedence matches web: the domain's own icon, else the org
        // icon on its primary domain, else the name's initial.
        var domain: [Channel] = []
        if cloud.isSignedIn, let org = cloud.currentOrg {
            let domains = org.domains ?? []
            if domains.isEmpty {
                // Legacy/single-domain payload: one chip keyed by the org id.
                domain = [Channel(id: org.id,
                                  label: org.domain ?? org.name,
                                  initials: MailAddress.initials(org.name),
                                  icon: "building.2.fill", seed: 99, online: true)]
            } else {
                domain = domains.enumerated().map { i, dom in
                    let isPrimary = dom.name == org.domain
                    let avatar = dom.iconUrl ?? (isPrimary ? org.iconUrl : nil)
                    return Channel(id: dom.id,
                                   label: dom.name,
                                   initials: String(dom.name.prefix(1)).uppercased(),
                                   avatarURL: avatar,
                                   seed: 99 + i, online: true)
                }
            }
        }
        return [unified] + domain + accountChannels
    }

    private static func logoAsset(for provider: String) -> String { ChannelAvatar.brandLogo(for: provider) }

    /// Publish the active account's provider for the folder drawer, and keep the
    /// selected folder valid across the email↔Meta boundary: entering a Meta
    /// account from a mail folder selects its first sub-view; leaving one resets
    /// to Inbox.
    private func syncActiveProvider() {
        let provider = activeAccountKey.flatMap { k in engine.accounts.first { $0.id == k }?.provider }
        activeProvider = provider
        // An MX domain chip shows its address folders (drawer / iPad sidebar).
        addressFolders.show(AccountKey.domainFilter(activeAccountKey).flatMap { dom in
            cloud.currentOrg.map { AddressFolderStore.Scope(orgId: $0.id, domain: dom) }
        })
        let metaFolders = provider.flatMap { MailFolder.meta(for: $0) }
        if let metaFolders {
            if !selectedFolder.isMeta { selectedFolder = metaFolders.first ?? .metaAll }
        } else if selectedFolder.isMeta {
            selectedFolder = .inbox
        }
    }

    /// The channel a conversation belongs to, for the row avatar's corner badge
    /// — only in the unified inbox, where channels are pooled and otherwise
    /// indistinguishable. nil in a single-channel view (the channel is implied).
    private func channelBadge(for convo: Conversation) -> Channel? {
        guard selectedChannel == "unified" else { return nil }
        // An MX row carries the ORG id as its account key, but a domain chip is keyed
        // by its own `dom_…` workspace id — so the id match below never landed and MX
        // threads showed no badge at all. Resolve the chip from the domain in the
        // thread's own addresses instead; a thread whose recipients are all off-domain
        // (or a legacy single-domain org) falls back to the org's first chip.
        if convo.isDomain {
            guard convo.accountKey == cloud.currentOrg?.id else { return nil }
            let chips = channels.filter { AccountKey.isDomain($0.id) }
            let addrs = "\(convo.toAddress) \(convo.fromAddress)".lowercased()
            return chips.first { addrs.contains("@" + $0.label.lowercased()) } ?? chips.first
        }
        return channels.first { $0.id == convo.accountKey }
    }

    /// Single, guarded entry point for opening a thread from the list. The row
    /// exposes two tap targets (avatar/padding via the Button, the text column via
    /// its Menu's primaryAction) and main-actor background work can delay the push,
    /// so collapse rapid/duplicate taps to one push until we're back at the list.
    private func open(_ convo: Conversation) {
        // In multi-select the avatar never navigates — a long-press that just entered
        // edit mode leaves the row's tap Button in-flight, and its trailing touch-up
        // would otherwise open the thread. Selection is toggled by the row itself.
        if !heldKeys.isDisjoint(with: [.shift, .command]) {
            bulk.modifiedTap(convo, shift: heldKeys.contains(.shift), openId: splitSelectedId)
            return
        }
        guard !bulk.editing else { return }
        if split != nil { showInSplit(convo); return }
        guard openGuardId == nil else { return }
        openGuardId = convo.id
        navPath.append(convo)
    }

    /// In multi-select a Shift-tap selects the range; any other tap toggles the row.
    private func editTap(_ convo: Conversation) {
        if heldKeys.contains(.shift) { bulk.modifiedTap(convo, shift: true, openId: splitSelectedId) }
        else { bulk.toggleSelect(convo) }
    }

    /// Desktop's list keys (web `lib/shortcuts.js`) for a hardware keyboard: arrows move
    /// the open thread in the iPad reader, Shift+arrows and ⌘A select, Esc clears, and
    /// E / ⌫ / ⇧I / ⇧U / ! act on the selection, or on the open thread when none.
    private var listKeyCommands: some View {
        Group {
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { bulk.extend(by: 1, openId: splitSelectedId) }.keyboardShortcut(.downArrow, modifiers: .shift)
            Button("") { bulk.extend(by: -1, openId: splitSelectedId) }.keyboardShortcut(.upArrow, modifiers: .shift)
            Button("") { bulk.selectAll() }.keyboardShortcut("a", modifiers: .command)
            Button("") { if bulk.editing { bulk.exitEditing() } }.keyboardShortcut(.escape, modifiers: [])
            Button("") { keyAct(.archive) }.keyboardShortcut("e", modifiers: [])
            Button("") { keyAct(.trash) }.keyboardShortcut(.delete, modifiers: [])
            Button("") { keyAct(.markRead) }.keyboardShortcut("i", modifiers: .shift)
            Button("") { keyAct(.markUnread) }.keyboardShortcut("u", modifiers: .shift)
            Button("") { keyAct(.spam) }.keyboardShortcut("1", modifiers: .shift)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// ↑ / ↓: the neighbouring thread opens in the iPad reader (multi-select ends).
    private func step(_ by: Int) {
        guard split != nil else { return }
        if bulk.editing { bulk.exitEditing() }
        let rows = loader.conversations
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex(where: { $0.id == splitSelectedId }) ?? (by > 0 ? -1 : rows.count)
        showInSplit(rows[max(0, min(rows.count - 1, at + by))])
    }

    private func keyAct(_ action: ConversationAction) {
        if bulk.editing { bulk.bulk(action); return }
        let rows = loader.conversations
        guard let at = rows.firstIndex(where: { $0.id == splitSelectedId }) else { return }
        let next = action.removesRow ? (rows.indices.contains(at + 1) ? rows[at + 1] : (at > 0 ? rows[at - 1] : nil)) : nil
        bulk.act(rows[at], action)
        if action.removesRow { if let next { showInSplit(next) } else { split?.convo = nil } }
    }

    /// Hand a thread to the iPad reader column. A destructive action there files the
    /// row and advances to its neighbour, like desktop (the phone pops instead).
    private func showInSplit(_ convo: Conversation) {
        guard let split else { return }
        bindSplit()
        split.convo = convo
    }

    /// Point the reader's actions at THIS list's loader/undo. Re-run on mount: in iPad
    /// portrait the list is rebuilt per sidebar push while the reader stays open.
    private func bindSplit() {
        guard let split else { return }
        split.owner = listId
        split.folder = selectedFolder
        split.onAdvance = { c, action in
            let next = neighbour(of: c)
            bulk.fileRow(c, action)
            split.convo = next
        }
        split.onSnooze = { c, date in
            let next = neighbour(of: c)
            bulk.snoozeRow(c, date: date)
            split.convo = next
        }
    }

    /// The row after `convo` (or before it, at the end of the list).
    private func neighbour(of convo: Conversation) -> Conversation? {
        let rows = loader.conversations
        guard let i = rows.firstIndex(where: { $0.id == convo.id }) else { return nil }
        if i + 1 < rows.count { return rows[i + 1] }
        return i > 0 ? rows[i - 1] : nil
    }

    /// What the loader reads for — the view's channel/folder/filter/query, resolved once.
    private var scope: InboxLoader.Scope {
        .init(accountKey: activeAccountKey, selectedChannel: selectedChannel, isDomainChannel: isDomainChannel,
              folder: selectedFolder, filterRaw: filter, filter: activeFilter, query: effectiveQuery,
              addressFolder: openAddressFolder?.key)
    }

    /// The address folder the list shows (Inbox of an MX domain chip with one picked).
    private var openAddressFolder: AddressFolder? {
        isDomainChannel && selectedFolder == .inbox ? addressFolders.openFolder : nil
    }

    /// "info@" in an address folder, else the mailbox's name.
    private var listTitle: String { openAddressFolder?.label ?? selectedFolder.title }

    /// Re-read the list for the current scope (input change + engine data events).
    private func reload() async { await loader.reload(scope, engine: engine, cloud: cloud) }

    var body: some View {
        // iPad: the shell owns navigation (this list is a split-view column, or a page
        // in the sidebar's stack in portrait), so no stack of our own.
        if split != nil { content } else { NavigationStack(path: $navPath) { content } }
    }

    private var content: some View {
            ZStack(alignment: .top) {
                list
                    .background(pageBackground.ignoresSafeArea())

                // Sticky collapsed bar — fades in once the big header scrolls past.
                collapsedBar
                    .opacity(collapsed ? 1 : 0)
                    .allowsHitTesting(collapsed)
            }
            // Undo / send toasts drop down from the top, just under the header.
            // Swipe one up to flick it away without waiting out its timer.
            .overlay(alignment: .top) {
                if !bulk.editing, let banner = undoController.banner {
                    undoToast(banner)
                        .padding(.top, Space.s2)
                        .offset(y: min(0, undoController.toastDrag))
                        .gesture(toastSwipeUp { withAnimation { undoController.banner = nil } })
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if !bulk.editing, cloud.lastSend != nil {
                    sendUndoToast
                        .padding(.top, Space.s2)
                        .offset(y: min(0, undoController.toastDrag))
                        .gesture(toastSwipeUp { withAnimation { cloud.lastSend = nil } })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: cloud.lastSend != nil)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: split == nil ? 70 : 0) }
            // Bulk-action bar takes the floating nav's place while multi-selecting —
            // RootTabs hides the nav (via chrome.editing), and this sits at the same
            // bottom offset (after the inset), so it reads as a drop-in replacement.
            .overlay(alignment: .bottom) {
                if bulk.editing {
                    selectionBar
                        .padding(.bottom, Space.s2)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if readAloud.phase == .listening {
                    // Hands-free triage window for an in-place "Read aloud" — sits above
                    // the floating nav; tap to dismiss (same as saying "no" / timing out).
                    // The pill owns the live mic-level observation, so it can't re-render
                    // the list behind it on every audio frame.
                    ReadAloudListeningPill()
                        .padding(.bottom, 78)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: readAloud.phase == .listening)
            // Ambient processing indicator: the triage worker is classifying /
            // summarizing in the background — a gradient hairline along the
            // bottom edge of the list while the queue is non-empty.
            .overlay(alignment: .bottom) {
                if engine.triage.isActive { ProcessingHairline() }
            }
            .animation(.easeInOut(duration: 0.3), value: engine.triage.isActive)
            .onChange(of: bulk.editing) { _, v in chrome.editing = v }
            // Search open hides the nav too; `searching` is local, so mirror the
            // editing pattern — clear on leave, restore on return (search survives
            // a round-trip into a thread, unlike multi-select).
            .onChange(of: showSearch) { _, v in chrome.searching = v }
            .onAppear {
                chrome.searching = showSearch
                bulk.bind(loader: loader, undo: undoController, engine: engine, cloud: cloud)
                bindSplit()
            }
            .onDisappear {
                // The reader outlives this list in iPad portrait; drop handlers that
                // would act on its unmounted loader/undo.
                if let split, split.owner == listId {
                    split.onAdvance = nil
                    split.onSnooze = nil
                }
                chrome.editing = false
                chrome.searching = false
                // Leaving the list (e.g. a tap that slipped through into a thread
                // while a long-press was entering multi-select) must never strand
                // selection mode — `editing` is local, so without this it survives
                // the round-trip and reappears as checkboxes with no action bar
                // (chrome.editing stayed false because `editing` never changed).
                // Returning to the list is always a clean exit from tap-and-hold.
                if bulk.editing { bulk.exitEditing() }
            }
            // Native bar hidden: the in-content header (hamburger inline beside the
            // big title) sits flush under the status bar with no wasted top row.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Conversation.self) {
                MessageView(convo: $0, folder: selectedFolder, onAdvance: advanceAfterReaderAction,
                            onSnooze: { convo, date in
                                bulk.snoozeRow(convo, date: date)
                                if !navPath.isEmpty { navPath.removeLast() }
                            })
            }
            .sheet(isPresented: $showActivity) {
                NavigationStack { ActivityView() }
            }
            .sheet(item: $composeDraft) { ComposeView(draft: $0) }
            .task(id: reloadKey) { await reload(); if !Task.isCancelled { searching = false } }
            // A triage result landed: upgrade the visible row in place (label +
            // one-liner preview) — no store re-query, no list rebuild. Only a
            // triage-scoped view needs a real reload, because a fresh label can
            // add a row it doesn't have yet.
            .onChange(of: engine.triagePatch) { _, patch in
                guard let patch else { return }
                if let i = loader.conversations.firstIndex(where: { $0.id == patch.key }) {
                    if let l = patch.label { loader.conversations[i].triageLabel = l }
                    if let pr = patch.priority { loader.conversations[i].triagePriority = pr }
                    if let s = patch.summaryShort { loader.conversations[i].aiSummaryShort = s }
                } else if selectedFolder.isTriage || activeFilter == .triaged {
                    Task { await reload() }
                }
            }
            // Debounce typing and gate on a minimum length: fragments shorter than
            // `minSearchChars` clear the search (full inbox shows) instead of scanning
            // the whole store on every keystroke. The spinner runs for the whole wait.
            .onChange(of: query) { _, value in
                searchDebounce?.cancel()
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                // Emptying the field (here or via the ✕) dismisses the keyboard.
                if value.isEmpty { searchFocused = false }
                guard trimmed.count >= Self.minSearchChars else {
                    searching = false
                    if !effectiveQuery.isEmpty { effectiveQuery = "" }
                    return
                }
                searching = true
                searchDebounce = Task {
                    try? await Task.sleep(for: Self.searchDebounceDelay)
                    guard !Task.isCancelled else { return }
                    if effectiveQuery != trimmed { effectiveQuery = trimmed }
                    else { searching = false }   // same term — no reload will fire to clear it
                }
            }
            // The pill set differs between domain (views) and offline (filters) —
            // reset to "All" on a channel switch if the current pill isn't valid.
            // The command palette lists the chips and can open one.
            .onChange(of: channels.map(\.id), initial: true) { _, _ in
                chrome.channelChoices = channels.map { (id: $0.id, label: $0.label) }
            }
            .onChange(of: chrome.pendingChannel, initial: true) { _, want in
                guard let want else { return }
                chrome.pendingChannel = nil
                if channels.contains(where: { $0.id == want }) { selectedChannel = want }
            }
            .onChange(of: selectedChannel, initial: true) { old, new in
                if let split {
                    if old == new, split.channel != new {
                        // First mount: iPad portrait remounts this list on every sidebar
                        // push, so resume the shell's chip (re-enters this handler).
                        selectedChannel = split.channel
                        return
                    }
                    // A real chip switch must not leave the previous chip's thread open
                    // (the resume above lands here with split.channel already == new).
                    if old != new, split.channel != new { split.convo = nil }
                    split.channel = new
                    split.channelLabel = channels.first { $0.id == new }?.label ?? "Unified"
                }
                if !filterOptions.contains(filter) { filter = "All" }
                syncActiveProvider()
                chrome.inboxAccountKey = isDomainChannel ? cloud.currentOrg?.id : activeAccountKey
            }
            .onAppear { syncActiveProvider() }
            // A swipe/menu action that files the open thread closes it in the iPad reader
            // (reader-driven actions already advanced to the neighbour first).
            .onChange(of: loader.conversations.map(\.id)) { old, new in
                if let id = split?.convo?.id, old.contains(id), !new.contains(id) { split?.convo = nil }
            }
            .onChange(of: engine.accounts.count) { _, _ in syncActiveProvider() }
            // A tapped new-mail notification: pop to root and push that conversation.
            // `.task(id:)` (not `.onChange`) so it also fires when this view is first
            // mounted with the key already set — the cold-launch tap and the
            // switched-from-another-tab cases. The id folds in `scenePhase == .active`
            // so the task re-fires once the scene becomes active (see the replace path).
            .task(id: notificationNavTrigger) {
                guard let key = notifications.pendingConversationKey else { return }
                // Don't clear the key before the `await`: it's this task's `id`, so
                // clearing it now cancels us at the suspension point below. Resolve
                // first, navigate, then clear last.
                guard let convo = await engine.store.read({ $0.conversation(key: key) }) else { return }
                showActivity = false
                // Never navigate until the scene is active. A tap that wakes the app
                // sets the key *before* activation, and pushing during the background→
                // foreground transition mounts the reader against the snapshot-flipped
                // window traits: it rendered with a light band down the page and its
                // load spinner's TimelineView never started ticking. The task re-fires
                // on activation (the scene-phase flag is baked into its id), so
                // returning here just defers the push a beat.
                guard scenePhase == .active else { return }
                // `.active` fires a beat before the window finishes its foreground
                // snapshot flip; mounting the reader in that gap lays it out against
                // stale traits — the light seam down the page. One runloop of settle.
                try? await Task.sleep(for: .milliseconds(50))
                guard scenePhase == .active, !Task.isCancelled else { return }
                // The reader (if any) was already popped without animation the moment
                // the key arrived — see the onChange below. Never push onto a non-empty
                // stack: the pop's re-fire of this task does the push instead.
                guard navPath.isEmpty else { return }
                if split != nil { showInSplit(convo) } else {
                    openGuardId = convo.id
                    navPath.append(convo)
                }
                notifications.pendingConversationKey = nil
            }
            // A notification tap always restarts from the list: drop whatever thread is
            // open the instant the key lands — usually while the app is still coming to
            // the foreground, so there's no in-flight transition to race. Animation off,
            // because an animated pop is still running when the push below fires and
            // SwiftUI then leaves the old MessageView on top of the new one
            // (tap → old thread, back → new thread).
            .onChange(of: notifications.pendingConversationKey) { _, key in
                guard key != nil, !navPath.isEmpty else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    navPath = NavigationPath()
                    openGuardId = nil
                }
            }
            // Returning to the list root clears the open guard so the next tap works.
            .onChange(of: navPath.count) { _, count in
                if count == 0 { openGuardId = nil }
            }
            // "Search mail" from a reader address token: pop the thread, open the
            // search field pre-filled with that address.
            .onChange(of: chrome.pendingSearch, initial: true) { _, value in
                guard let value else { return }
                chrome.pendingSearch = nil
                navPath = NavigationPath()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSearch = true
                    query = value
                }
            }
            .refreshable {
                if isDomainChannel { cloudRefresh += 1; addressFolders.reloadActive() }
                else { engine.sync(accountKey: activeAccountKey) }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
    }

    /// Unread count next to the title. Unified shows the combined channel + MX total —
    /// the same two halves that make up the app-icon badge (`AppBadge`), so the
    /// on-screen `(N)` matches the icon from one source; a specific chip shows just its
    /// loaded rows.
    private var unreadCount: Int {
        activeAccountKey == nil ? AppBadge.combinedUnread : loader.conversations.filter { $0.unread }.count
    }

    /// The header's leading control: the folder hamburger on iPhone; on iPad the folders
    /// live in the sidebar, so a back chevron when this list is a pushed sidebar page.
    @ViewBuilder private func leadingControl(_ size: CGFloat) -> some View {
        if split == nil {
            hamburger(size)
        } else if let onBack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(AppFont.glyph(size, .semibold))
                    .foregroundStyle(p.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Folders")
        } else if let onShowFolders {
            Button(action: onShowFolders) {
                Image(systemName: "sidebar.left")
                    .font(AppFont.glyph(size - 2, .semibold))
                    .foregroundStyle(p.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .accessibilityLabel("Show folders")
        }
    }

    /// Hamburger button reused by the big in-content header and the collapsed bar —
    /// opens the folder switcher. Uses the softer secondary gray (per the reference).
    private func hamburger(_ size: CGFloat) -> some View {
        Button { showFolders = true } label: {
            Image(systemName: "line.3.horizontal")
                .font(AppFont.glyph(size, .semibold))
                .foregroundStyle(p.textSecondary)
                // Optically center the glyph with the all-caps title — the symbol's
                // line box centers ~2.5pt above the caps' visual center, so nudge down.
                .offset(y: 1.5)
        }
        .buttonStyle(.plain)
    }

    /// New-message button: opens the compose sheet with a blank draft, seeded with
    /// the channel currently being viewed (a domain chip resolves to its org, which
    /// is what ComposeView keys a domain identity by). On "Unified" it seeds nothing
    /// and the sheet's From picker falls back to the first identity.
    private var composeButton: some View {
        headerIcon("square.and.pencil") {
            composeDraft = ComposeDraft(fromAccountKey: isDomainChannel ? cloud.currentOrg?.id : activeAccountKey)
        }
    }

    /// A right-aligned header action icon (search / notifications). The bell's glyph
    /// is filled with the pink→violet→orange gradient.
    @ViewBuilder
    private func headerIcon(_ name: String, gradient: Bool = false, action: @escaping () -> Void) -> some View {
        if gradient {
            IconButton(name, tint: LinearGradient(colors: p.ringColors, startPoint: .topLeading, endPoint: .bottomTrailing), action: action)
        } else {
            IconButton(name, tint: p.textSecondary, action: action)
        }
    }

    /// Sync button — spins continuously while a sync is in flight.
    private var syncButton: some View {
        IconButton("arrow.triangle.2.circlepath", glyph: AppFont.md(.semibold), tint: p.textSecondary, rotation: syncSpin) {
            if isDomainChannel { cloudRefresh += 1; addressFolders.reloadActive() } else { engine.sync(accountKey: activeAccountKey) }
        }
        .onChange(of: engine.syncing) { _, on in
            if on {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { syncSpin = 360 }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { syncSpin = 0 }
            }
        }
        .onAppear {
            if engine.syncing {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { syncSpin = 360 }
            }
        }
    }

    /// Sticky top bar shown while scrolled: hamburger + centered "Inbox". Its
    /// background bleeds up behind the status bar so list content scrolls under it.
    private var collapsedBar: some View {
        HStack(spacing: Space.s2 + 2) {
            leadingControl(18)
            Text(listTitle)
                .font(AppFont.title3.smallCaps())
                .foregroundStyle(p.textSecondary)
            if unreadCount > 0 {
                Text("(\(unreadCount))")
                    .font(AppFont.base(.semibold))
                    .foregroundStyle(p.textSecondary.opacity(0.7))
            }
            Spacer(minLength: 0)
            headerIcon("magnifyingglass") {
                withAnimation(.easeOut(duration: 0.2)) { showSearch.toggle() }
                if showSearch { searchFocused = true } else { query = "" }
            }
            syncButton
            composeButton
            headerIcon("bell", gradient: true) { showActivity = true }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .background(
            p.bgBase.opacity(0.4)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        )
        .overlay(alignment: .bottom) { Rectangle().fill(p.borderSubtle).frame(height: 0.5) }
    }

    /// Custom rounded search field (replaces `.searchable`) so it scrolls away with
    /// the rest of the header instead of docking under the nav bar.
    private var searchField: some View {
        HStack(spacing: Space.s2) {
            // The leading glyph doubles as the loading indicator: it swaps to a
            // spinner while a debounced search is in flight.
            if searching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(AppFont.base(.medium))
                    .foregroundStyle(p.textTertiary)
            }
            TextField("Search mail", text: $query)
                .font(AppFont.md(.regular))
                .foregroundStyle(p.textPrimary)
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                // Clearing exits search entirely — drops focus (keyboard dismisses)
                // and closes the field, so `chrome.searching` flips back and the
                // floating nav returns. Leaving it open stranded the nav hidden.
                Button {
                    query = ""
                    searchFocused = false
                    withAnimation(.easeOut(duration: 0.2)) { showSearch = false }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(p.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2 + 3)
        .background(p.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Page backdrop: a steel-navy glow at the very top fading into the base color
    /// (replaces flat black, per the design reference).
    /// Groovebox swaps it for the guidebook grid the list well floats over.
    @ViewBuilder private var pageBackground: some View {
        if p.guidebookGrid {
            GrooveboxScene(shapes: false)
        } else {
            LinearGradient(
                stops: [
                    .init(color: p.bgPageGlow, location: 0),
                    .init(color: p.bgBase, location: 0.32)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    /// Inset card horizontal margin (page background shows on either side).
    /// ponytail: local to the inbox list while the "well" frame is under review —
    /// the shared `CardStyle.inset` still drives the reader + calendar cards.
    /// The phone's list is a floating card; a split column runs edge to edge.
    private var cardInset: CGFloat { split != nil ? 0 : 8 }

    /// Per-row background that composes the inset conversation list. The list is a
    /// **well pressed into the page**, matching every desktop panel: a dark groove
    /// outline, a short inner top shadow on the first row and a faint inner light
    /// hairline. It replaces the card that was lit from above (20pt radius, a 22%
    /// white top lip and a 72pt light wash falling over the first rows) — nothing
    /// else in either app is lit that way, which is what read as "shiny".
    /// `header: true` swaps the inset row hairline for a full-width groove — the
    /// column header's own bottom edge, not a divider between two rows.
    private func cardBG(first: Bool, last: Bool, header: Bool = false) -> some View {
        let r = split != nil ? 0 : (p.panelRadius ?? 8)
        let radii = RectangleCornerRadii(
            topLeading: first ? r : 0, bottomLeading: last ? r : 0,
            bottomTrailing: last ? r : 0, topTrailing: first ? r : 0
        )
        let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
        // Light mode drops the groove entirely — the list is a borderless light
        // card on the grey canvas; the "well" outline is a dark-theme device.
        let groove = p.isDark ? Color.scrim(0.45) : .clear
        return ZStack {
            shape.fill(p.bgPanel)
            // Light falls *into* the well: a short dark gradient under the top lip.
            // Fixed height, not a fraction of the row — tall rows must not stretch it.
            if first, p.isDark {
                LinearGradient(colors: [.scrim(0.26), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 5)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipShape(shape)
            }
            // Continuous groove sides.
            HStack(spacing: 0) {
                Rectangle().fill(groove).frame(width: 1)
                Spacer(minLength: 0)
                Rectangle().fill(groove).frame(width: 1)
            }
            // Rounded edges carry the groove around the corner…
            if first || last {
                shape.strokeBorder(groove, lineWidth: 1)
            }
            // …with the faint inner light hairline of the desktop's --panel-groove.
            shape.strokeBorder(Color.bevel(0.03), lineWidth: 1)
            if header {
                VStack { Spacer(); Rectangle().fill(p.isDark ? groove : p.borderSubtle).frame(height: 1) }
            } else if !last {
                VStack { Spacer(); Rectangle().fill(p.borderSubtle).frame(height: 1).padding(.leading, Space.s5) }
            }
        }
        .padding(.horizontal, cardInset)
    }

    /// The well's header strip: the filter tabs, flush on top of the rows, with a
    /// one-line count of what's loaded on the right. Replaces the free-floating
    /// `FilterPills` that used to sit on the page above the card.
    ///
    /// The tabs scroll horizontally — a domain channel's saved team views can run
    /// well past the screen width, where the old pill row simply clipped them.
    private var columnHeader: some View {
        HStack(spacing: Space.s3) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s4) {
                    ForEach(filterOptions, id: \.self) { opt in
                        let active = opt == filter
                        Text(opt)
                            .font(AppFont.xs2(active ? .semibold : .medium))
                            .foregroundStyle(active ? p.textPrimary : p.textTertiary)
                            .padding(.vertical, Space.s2 + 2)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(active ? p.accentViolet : .clear)
                                    .frame(height: 1.5)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { filter = opt } }
                    }
                }
                .padding(.horizontal, Space.s4)
            }
            Text(headerSummary)
                .font(AppFont.xs3)
                .foregroundStyle(p.textMuted)
                .padding(.trailing, Space.s4)
        }
    }

    /// The header's count — the rows actually on screen, not the app-wide badge
    /// (`unreadCount`, which pools every channel for the title and the app icon).
    private var headerSummary: String {
        let unread = loader.conversations.filter(\.unread).count
        return unread > 0 ? "\(loader.conversations.count) · \(unread) unread" : "\(loader.conversations.count)"
    }

    /// No card of rows follows the header — empty/error states render on the page,
    /// outside the well, so the header has to close the well itself.
    private var headerClosesCard: Bool {
        if searchPending { return true }
        if selectedFolder == .outbox && effectiveQuery.isEmpty { return loader.outbox.isEmpty }
        if selectedFolder == .drafts && effectiveQuery.isEmpty { return draftStore.drafts.isEmpty }
        return loader.loadError != nil || loader.conversations.isEmpty
    }

    /// The whole surface scrolls as one: a big "Inbox" title with the hamburger
    /// inline beside it, the search field, then the channel tracker — all ride at
    /// the top of the list and scroll away. Past a threshold the title collapses
    /// into a sticky inline bar (hamburger + centered title). The conversation rows
    /// sit in a recessed well (`cardBG`) whose first element is `columnHeader`.
    private var list: some View {
        List {
            HStack(spacing: Space.s2 + 2) {
                // No leading control in edit mode — cancelling lives on the bulk bar's
                // trailing ✕ (next to the floating-nav slot it occupies).
                if !bulk.editing { leadingControl(20) }
                Text(bulk.editing ? "\(bulk.selection.count) Selected" : listTitle)
                    .font(AppFont.title.smallCaps())
                    .foregroundStyle(p.textSecondary)
                if !bulk.editing && unreadCount > 0 {
                    Text("(\(unreadCount))")
                        .font(AppFont.title2)
                        .foregroundStyle(p.textSecondary.opacity(0.7))
                }
                Spacer()
                if bulk.editing {
                    Button(bulk.allSelected ? "Deselect all" : "Select all") { bulk.toggleSelectAll() }
                        .font(AppFont.base(.semibold))
                        .foregroundStyle(p.accentViolet)
                        .buttonStyle(.plain)
                } else {
                    headerIcon("magnifyingglass") {
                        withAnimation(.easeOut(duration: 0.2)) { showSearch.toggle() }
                        if showSearch { searchFocused = true } else { query = "" }
                    }
                    syncButton
                    composeButton
                    headerIcon("bell", gradient: true) { showActivity = true }
                }
            }
            .padding(.horizontal, Space.s4)
            // iPad: a 44pt row flush with the top, so the title lines up with the
            // sidebar header and the reader's title bar beside it.
            .frame(minHeight: split == nil ? nil : 44)
            .padding(.top, split == nil ? Space.s2 : (underStatusBar ? Space.s3 : 0))
            .padding(.bottom, Space.s2)
            .plainListRow()

            if showSearch || !query.isEmpty {
                searchField
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s2)
                    .plainListRow()
            }

            ChannelsRow(channels: channels, selection: $selectedChannel)
                .padding(.bottom, Space.s4)
                .plainListRow()

            if let f = openAddressFolder, f.kind == .shared, !f.canReply {
                ReadOnlyFolderNotice(folder: f)
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s3)
                    .plainListRow()
            }

            // Flush against the top of the well — the filter tabs are part of the
            // list now, not a row of pills floating on the page above it.
            columnHeader
                .listRowInsets(EdgeInsets())
                .listRowBackground(cardBG(first: true, last: headerClosesCard, header: !headerClosesCard))
                .listRowSeparator(.hidden)

            if searchPending {
                // Text in the search field but no search applied yet (below the
                // min-chars gate, or the debounce/fetch is still in flight) — don't
                // show the normal inbox behind an active search; it reads as
                // bogus results.
                EmptyState(
                    systemImage: "magnifyingglass",
                    title: searchTooShort ? "Keep typing" : "Searching\u{2026}",
                    message: searchTooShort
                        ? "Search needs at least \(Self.minSearchChars) characters."
                        : "Looking for \u{201C}\(trimmedQuery)\u{201D}\u{2026}"
                )
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s8)
                .plainListRow()
            } else if selectedFolder == .outbox && effectiveQuery.isEmpty {
                OutboxListSection(
                    outbox: loader.outbox,
                    cardBackground: { _, last in AnyView(cardBG(first: false, last: last)) },
                    onCancel: { item in
                        Log.action.info("outbox delete \(item.key)")
                        Task { _ = await engine.deleteOutbox(accountKey: item.accountKey, outboxKey: item.key) }
                    },
                    onRetry: { item in
                        Log.action.info("outbox retry \(item.key)")
                        Task { _ = await engine.retryOutbox(accountKey: item.accountKey, outboxKey: item.key) }
                    }
                )
            } else if selectedFolder == .drafts && effectiveQuery.isEmpty {
                DraftsListSection(
                    drafts: draftStore.drafts,
                    cardBackground: { _, last in AnyView(cardBG(first: false, last: last)) },
                    onResume: { d in
                        composeDraft = ComposeDraft(savedDraftId: d.id, fromAccountKey: d.fromAccountKey,
                                                    to: d.to, cc: d.cc, bcc: d.bcc, subject: d.subject, body: d.body)
                    },
                    onDelete: { draftStore.delete(id: $0) }
                )
            } else if let loadError = loader.loadError {
                // A failed local read (disk I/O, corruption) — surface it rather than
                // letting it read as an empty mailbox.
                inboxErrorState(loadError)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.s8)
                    .plainListRow()
            } else if loader.conversations.isEmpty {
                EmptyState(
                    systemImage: effectiveQuery.isEmpty ? "tray" : "magnifyingglass",
                    title: effectiveQuery.isEmpty ? "All clear" : "No results",
                    message: effectiveQuery.isEmpty
                        ? "Nothing in \(filter == "All" ? listTitle : filter.lowercased()) right now."
                        : "No conversations match \u{201C}\(effectiveQuery)\u{201D}."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s8)
                .plainListRow()
            } else {
                ForEach(Array(loader.conversations.enumerated()), id: \.element.id) { idx, convo in
                    // The HStack is the row: its transition runs when the row is filed
                    // (archive/trash/snooze) or restored by undo. The check circle
                    // slides in on its own, so the row body's branch swap below keeps
                    // .transition(.identity): toggling edit mode swaps Button <-> menu/swipe
                    // variants, and the default fade out/in reads as the row vanishing
                    // for a beat under withAnimation.
                    HStack(spacing: Space.s3) {
                        if bulk.editing {
                            Button { editTap(convo) } label: { checkCircle(convo) }
                                .buttonStyle(.plain)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                        if bulk.editing {
                            Button { editTap(convo) } label: { selectableRow(convo) }
                                .buttonStyle(.plain)
                                .transition(.identity)
                        } else {
                            ConversationRowActions(
                                convo: convo, channelBadge: channelBadge(for: convo),
                                isSent: selectedFolder == .sent, preparingForwardId: preparingForwardId,
                                onAvatarLongPress: {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    bulk.enterEditing(selecting: convo)
                                },
                                onOpen: { open(convo) },
                                onReadAloud: { readAloud(convo) },
                                onForward: { forwardRow(convo) },
                                onAct: { bulk.act(convo, $0) },
                                onQuick: { bulk.quick(convo, $0) },
                                onSnooze: { bulk.snoozeRow(convo, date: $0) })
                            .transition(.identity)
                        }
                    }
                    .background { selectedRowBG(bulk.editing ? bulk.selection.contains(convo.id) : splitSelectedId == convo.id) }
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    .cardListRow(background: cardBG(first: false, last: idx == loader.conversations.count - 1))
                }
            }
        }
        .listStyle(.plain)
        .background { if !showSearch { listKeyCommands } }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, split == nil ? nil : 0, for: .scrollContent)
        .ignoresSafeArea(.container, edges: underStatusBar ? .top : [])
        // Up there the system's soft top edge would fade the header out.
        .scrollEdgeEffectHidden(underStatusBar, for: .top)
        .modifier(CollapseOnScroll(collapsed: $collapsed))
    }

    /// Shown when the local mailbox read fails (disk I/O, DB corruption). Distinct from
    /// the "All clear" empty state so a failed read isn't mistaken for no mail, with the
    /// raw engine detail and a retry.
    private func inboxErrorState(_ detail: String) -> some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(AppFont.glyph(46, .regular))
                .foregroundStyle(p.accentDanger)
                .padding(.bottom, Space.s1)
            Text("Couldn’t load your inbox")
                .font(AppFont.lg)
                .foregroundStyle(p.textPrimary)
            Text("This phone couldn't read your mail from storage. Your mail is safe on the server.")
                .font(AppFont.sm)
                .foregroundStyle(p.textTertiary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(AppFont.xs)
                .foregroundStyle(p.textMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Button { Task { await reload() } } label: {
                Text("Try again")
                    .font(AppFont.sm(.semibold))
                    .foregroundStyle(p.accentViolet)
            }
            .buttonStyle(.plain)
            .padding(.top, Space.s2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.s8)
    }

    private func undoToast(_ banner: UndoBanner) -> some View {
        let subject = banner.primary?.subject.isEmpty == false ? banner.primary!.subject : "(No subject)"
        // One row → show its subject; a bulk action → show the count instead.
        let subtitle = banner.count > 1 ? "\(banner.count) conversations" : subject
        return ToastRow(icon: banner.action.icon, title: banner.action.title,
                        subtitle: subtitle, avatar: undoToastChannel(banner),
                        colors: toastColors(for: banner.action)) {
            Button("Undo") { bulk.undo() }
                .font(AppFont.sm(.semibold))
                .foregroundStyle(p.accentViolet)
        }
    }

    /// The channel avatar for the undo toast badge — resolved only when every
    /// affected conversation shares one account, so a mixed bulk action keeps the
    /// neutral action glyph rather than misrepresenting one channel.
    private func undoToastChannel(_ banner: UndoBanner) -> Channel? {
        let keys = Set(banner.items.map { $0.convo.accountKey })
        guard keys.count == 1, let key = keys.first else { return nil }
        return channels.first { $0.id == key }
    }

    /// Swipe-up on a toast: follow the finger (upward only via the `offset` clamp),
    /// dismiss past the distance/flick threshold, else spring back.
    private func toastSwipeUp(dismiss: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in undoController.toastDrag = v.translation.height }
            .onEnded { v in
                if v.translation.height < -30 || v.predictedEndTranslation.height < -80 {
                    dismiss()
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { undoController.toastDrag = 0 }
            }
    }

    /// Per-action accent for the toast's gradient border/glow — mirrors the web
    /// variants: destructive (trash) reads coral, triage (archive/spam/quadrant)
    /// reads amber, everything else stays the neutral inbox violet.
    private func toastColors(for action: ConversationAction) -> [Color] {
        switch action {
        case .trash:
            return [ChannelColor.coral, ChannelColor.coralDeep]      // coral — destructive
        case .archive, .spam, .setQuadrant, .clearQuadrant:
            return [ChannelColor.amber, ChannelColor.amberDeep]      // amber — triage
        default:
            return navIconColors                                  // violet — neutral
        }
    }

    /// "Message sent · Undo" — shown briefly after a domain send (the server holds
    /// delivery for the undo window, so Undo reverts it to a draft).
    private var sendUndoToast: some View {
        ToastRow(icon: "paperplane.fill", title: "Message sent", tint: p.accentSuccess) {
            Button("Undo") {
                Task { await cloud.undoLastSend(); await MainActor.run { cloudRefresh += 1 } }
            }
            .font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet)
        }
    }

    // ── Multi-select / bulk actions ──


    /// Edit mode's leading check circle; the symbol swap animates in place.
    private func checkCircle(_ convo: Conversation) -> some View {
        let on = bulk.selection.contains(convo.id)
        return Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(AppFont.glyph(22))
            .foregroundStyle(on ? p.accentViolet : p.textTertiary)
            .contentTransition(.symbolEffect(.replace))
    }

    /// Groovebox's selected row: a solid fill with a lavender ring (no wash, no
    /// rail). Themes without `selectedRowFill` keep just the check circle.
    @ViewBuilder private func selectedRowBG(_ on: Bool) -> some View {
        // Themes without a selection fill still need the iPad's open-thread highlight.
        if on, let fill = p.selectedRowFill ?? (split != nil ? p.accentViolet.opacity(0.12) : nil) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(fill)
                .overlay {
                    if let outline = p.selectionOutline {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(outline, lineWidth: 1.5)
                    }
                }
                .padding(.horizontal, -Space.s2)
                .padding(.vertical, -Space.s1)
        }
    }

    /// The selectable (edit-mode) row body: the standard `ConversationRow` with no
    /// menu/swipe, whole area tappable.
    private func selectableRow(_ convo: Conversation) -> some View {
        ConversationRow(convo: convo, channelBadge: channelBadge(for: convo), isSent: selectedFolder == .sent)
            .contentShape(Rectangle())
    }

    /// "Read aloud" from the row's long-press menu: read the thread aloud + arm voice
    /// triage right here on the inbox (no navigation). A spoken "trash"/"archive" files
    /// it and animates the row out, just like the menu/swipe actions.
    private func readAloud(_ convo: Conversation) {
        readAloud.start(convo: convo, engine: engine, voice: voice,
                        speaker: speaker, presence: presence) { action in bulk.act(convo, action) }
    }

    /// Bottom bulk-action bar shown in edit mode — it takes the floating nav's place
    /// and mirrors it exactly: an intrinsic-width centered capsule of 48×48 icon
    /// buttons (Move to Inbox / Read / Archive / Triage / Trash), same icon size,
    /// weight, spacing, and padding as `FloatingNavBar`. Disabled while nothing's
    /// selected. inbox2 has no flag concept — the triage slot is the quadrant submenu.
    private var selectionBar: some View {
        HStack(spacing: Space.s1) {
            // Archive/Trash folders: bulk "Move to Inbox" replaces the redundant
            // same-folder removal button.
            if let restore = folderRestoreAction {
                bulkButton("tray.and.arrow.down") { bulk.bulk(restore) }
            }
            bulkButton("envelope.open") { bulk.bulk(.markRead) }
            if selectedFolder != .archive {
                bulkButton("archivebox") { bulk.bulk(.archive) }
            }
            if !isDomainChannel {
                Menu {
                    ConversationMenus.triageItems { bulk.bulk($0) }
                } label: {
                    bulkIcon("square.grid.2x2").foregroundStyle(idleIconColor)
                }
                .disabled(bulk.selection.isEmpty)
            }
            if selectedFolder != .trash {
                bulkButton("trash") { bulk.bulk(.trash) }
            }
            cancelSelectionButton
        }
        .padding(.horizontal, Space.s2)
        .padding(.vertical, Space.s1 + 2)
        .glowCapsule(colors: navIconColors)
    }

    /// Exits edit mode — a small, darker recessed disc (the floating nav's compose-
    /// button treatment, shrunk) on the bar's trailing edge. Always enabled (cancelling
    /// shouldn't depend on having a selection); replaces the old top-bar "Cancel".
    private var cancelSelectionButton: some View {
        Button { bulk.exitEditing() } label: {
            Image(systemName: "xmark")
                .font(AppFont.xs(.semibold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(p.bgBase.opacity(0.67)))
                        .overlay(Circle().stroke(Color.bevel(0.12), lineWidth: 0.5))
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
    }

    private func bulkButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { bulkIcon(icon) }
            .buttonStyle(BulkActionStyle(idle: idleIconColor, pressed: navIconColors))
            .disabled(bulk.selection.isEmpty)
    }

    /// A bulk-bar icon — same 19pt semibold glyph in a 48×48 frame as the floating nav.
    /// Color is supplied by the button style (`BulkActionStyle`) or the caller (the
    /// Triage menu), so it stays gray idle and only lights up purple on press.
    private func bulkIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(AppFont.title2)
            .frame(width: 48, height: 48)
            .contentShape(Circle())
    }

    /// Bulk-bar idle glyph color — the floating nav's exact gray inactive treatment:
    /// `textSecondary` at 0.45 opacity (see `FloatingNavBar.navButton`), dimmer still
    /// while nothing's selected. Purple is reserved for the pressed/active state.
    private var idleIconColor: Color { p.textSecondary.opacity(bulk.selection.isEmpty ? 0.3 : 0.45) }

    /// Bulk-bar action button style: a gray idle glyph that flashes the accent gradient
    /// (+ a slight scale) while pressed — purple signals the active/touched state only.
    private struct BulkActionStyle: ButtonStyle {
        var idle: Color
        var pressed: [Color]
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(configuration.isPressed
                    ? AnyShapeStyle(LinearGradient(colors: pressed, startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(idle))
                .scaleEffect(configuration.isPressed ? 0.88 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    /// Forward the conversation's latest message from the inbox list. Loads the
    /// message, downloads its attachments (offline channels), then opens the
    /// composer prefilled with the forward body + files. Mirrors the reader's
    /// Forward; the menu shows "Preparing…" while the bytes download.
    private func forwardRow(_ convo: Conversation) {
        guard preparingForwardId == nil else { return }
        preparingForwardId = convo.id
        Task {
            let draft = await ReplyComposer.forwardDraft(for: convo, engine: engine, cloud: cloud)
            await MainActor.run {
                preparingForwardId = nil
                composeDraft = draft
            }
        }
    }

    /// A destructive action fired from inside the reader: drop the acted row and
    /// slide the open thread to the next conversation in the folder (or the previous
    /// one if it was last), mirroring the web reading pane + desktop
    /// `removeAndSelectNext`. Pops back to the list only once the folder is empty.
    /// The list re-query reconciles with the store once the write-back lands.
    private func advanceAfterReaderAction(_ convo: Conversation, _ action: ConversationAction) {
        // Mobile: a destructive action returns to the folder list we came from
        // rather than advancing into the next thread (desktop advances). File the
        // row the same way the swipe/menu path does — the toast lands on the list
        // we're popping back to. The reader already fired the write-back + badge.
        bulk.fileRow(convo, action)
        if !navPath.isEmpty { navPath.removeLast() }
    }

}

/// The two list-row chromes this screen's `List` uses everywhere — one place owns
/// the insets/background/separator trio instead of repeating it per row. Internal so
/// the extracted `OutboxListSection` / `DraftsListSection` share the same chrome.
extension View {
    /// Full-bleed transparent row (header, search, pills, empty/error states).
    func plainListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// A row inside the inset conversation card (see `cardBG`), with the standard
    /// card insets.
    func cardListRow(background: some View) -> some View {
        listRowInsets(EdgeInsets(top: Space.s2, leading: Space.s5, bottom: Space.s2, trailing: Space.s5))
            .listRowBackground(background)
            .listRowSeparator(.hidden)
    }
}
