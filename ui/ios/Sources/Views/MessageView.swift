import SwiftUI
import UIKit

/// A conversation reader: an optional AI summary, then the message thread as a
/// stack of per-message cards (newest expanded, older collapsed), each rendered
/// through the shared-JS self-sizing body view, with a conversation-level actions
/// bar pinned at the bottom. Mirrors the desktop MessageDetails (thread of
/// MessageCards) + MessageActions. Reads live from the store; actions write back
/// through the engine and pop the view.
struct MessageView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    @EnvironmentObject private var chrome: ChromeModel
    @EnvironmentObject private var voice: VoiceEngineManager
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var presence: VoicePresence
    let convo: Conversation
    /// The folder this thread was opened from — drives which destructive actions
    /// are hidden (Archive in Archive/Trash/Sent, Trash in Trash). Defaults to
    /// `.inbox` for readers opened without a folder context (e.g. a notification tap).
    var folder: MailFolder = .inbox
    /// After a destructive action (archive/trash/spam/move-to-inbox), the list
    /// advances the open thread to the next conversation instead of popping. When
    /// nil (no list context), the reader just dismisses.
    var onAdvance: ((Conversation, ConversationAction) -> Void)? = nil
    /// Snooze is a cloud call, not a `ConversationAction`, so it hands off separately —
    /// the list owns dropping the row + nudging the badge, exactly as its own snooze
    /// does. When nil (no list context) the reader files it itself and dismisses.
    var onSnooze: ((Conversation, Date) -> Void)? = nil
    /// Root of the iPad reader column — nothing to go back to, so no chevron.
    var embedded = false
    /// How the reader leaves when it isn't a pushed screen (iPad: clear the column).
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var markRead: MarkReadManager
    // Read-aloud + voice triage runs through the shared app-level controller, so the
    // exact same flow drives the inbox row's "Read aloud" action without leaving it.
    @EnvironmentObject private var readAloud: ReadAloudController
    @State private var messages: [Message] = []
    /// False until the first `load()` for this thread resolves. The message read is
    /// async (off-main DB), so the view first renders with `messages == []`; without
    /// this gate the "No messages" empty state flashes until the read lands — visible
    /// for seconds on a notification tap, when a foreground sync holds the DB.
    @State private var loaded = false
    @State private var sealedLocked = false
    @State private var triedSavedKey: String?
    @State private var showUnlock = false
    /// On open, a multi-message thread scrolls so the last (expanded) message's header
    /// sits at the top. The bodies are WebViews that report their height asynchronously,
    /// so a single scroll at load time lands short: the thread isn't tall enough yet and
    /// `scrollTo` clamps at the content end. `anchorID` therefore stays set and every
    /// body-height report re-anchors, until `anchorUntil` passes (heights have settled;
    /// after that the scroll position is the user's).
    @State private var anchorID: String?
    @State private var anchorUntil = Date.distantPast
    /// Bumped on each body resize — `onChange` needs a changing value to fire on.
    @State private var anchorTick = 0
    @State private var working = false
    /// True while the triage worker still owes this thread current summaries —
    /// drives the processing hairline under the header.
    @State private var summariesProcessing = false
    /// A fresher store read of this thread than the navigation snapshot `convo` —
    /// updated on every `dataVersion` bump so summaries rewritten while the reader
    /// is open (the worker, or "Process with") show without re-navigating.
    @State private var refreshed: Conversation?
    /// True while a forced "Process with" run is in flight (drives the hairline
    /// independently of the worker-queue state).
    @State private var reprocessing = false
    /// A failed "Process with" run, surfaced as an alert.
    @State private var reprocessError: String?
    @State private var composeDraft: ComposeDraft?
    /// True while a Forward's attachments are downloading before the sheet opens.
    @State private var preparingForward = false
    @State private var dwellTask: Task<Void, Never>?
    @State private var didMarkRead = false
    // Domain (inbox2 team pool) collaboration UI lives in `DomainCollabSection`.
    private var p: ThemePalette { theme.palette }

    /// The freshest view of this thread: the live store read when one landed,
    /// else the navigation snapshot.
    private var current: Conversation { refreshed ?? convo }

    private var summaryBullets: [String] {
        guard let s = current.aiSummary, !s.isEmpty else { return [] }
        let parts = s.split(whereSeparator: { $0 == "\n" || $0 == "•" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [s] : parts
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned above the list: the reader scrolls to the last message.
            if sealedLocked { sealedBanner.padding(.vertical, Space.s2) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: Space.s3) {
                        if convo.isDomain {
                            DomainCollabSection(convo: convo)
                        }
                        if !summaryBullets.isEmpty {
                            AISummaryPanel(bullets: summaryBullets,
                                           sentimentPositive: messages.last?.sentimentPositive,
                                           intentKind: messages.last?.intentKind)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                            MessageCard(message: msg, isLast: idx == messages.count - 1,
                                        threadCount: messages.count,
                                        accountKey: convo.accountKey,
                                        mayHaveAttachments: convo.hasAttachment,
                                        fromEmailOverride: domainFromEmail,
                                        onBodyResize: { anchorTick += 1 },
                                        onInviteAnswered: archivesOnRSVP ? { act(.archive) } : nil)
                        }
                        if messages.isEmpty {
                            if loaded {
                                EmptyState(systemImage: "envelope", title: "No messages",
                                           message: "Its messages haven't downloaded yet.")
                                    .padding(.top, Space.s8)
                            } else {
                                // Still resolving the async read — show a spinner, not the
                                // empty state, so the thread doesn't read as empty for a beat.
                                GradientSpinner(size: 22)
                                    .padding(.top, Space.s8)
                            }
                        }
                    }
                    .padding(.vertical, Space.s3)
                }
                // Land on the open (last) message rather than the top of a long thread:
                // anchor its header to the top so the reader starts where reading does.
                // Re-runs on every body-height report until the settle window closes.
                .onChange(of: anchorID) { anchor(proxy) }
                .onChange(of: anchorTick) { anchor(proxy) }
            }
        }
        .background(p.bgBase.ignoresSafeArea())
        .navigationTitle(convo.subject)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if !embedded {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(AppFont.title3)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) { ReaderAudioButton(convo: convo, onTriage: applyVoiceTriage) }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .task(id: convo.id) { load() }
        // Ambient processing indicator: this thread's summaries are stale (a newer
        // message than the one they were generated for) and the triage worker is
        // running — a gradient hairline just below the header until they land.
        .task(id: "\(engine.dataVersion)|\(engine.triage.pending)") { refreshSummariesProcessing() }
        .overlay(alignment: .top) {
            if summariesProcessing || reprocessing { ProcessingHairline() }
        }
        .alert("Processing failed", isPresented: .init(
            get: { reprocessError != nil },
            set: { if !$0 { reprocessError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(reprocessError ?? "")
        }
        // The hands-free triage window: a listening orb + the keywords on offer. The pill
        // owns the live mic-level observation (scoped to this thread), so the reader
        // doesn't re-render — and its open actions menu doesn't flicker — per audio frame.
        .overlay(alignment: .bottom) {
            ReadAloudListeningPill(conversationId: convo.id)
                .padding(.bottom, Space.s5)
        }
        .onAppear { chrome.detailScreens += 1 }
        .onDisappear {
            chrome.detailScreens = max(0, chrome.detailScreens - 1)
            dwellTask?.cancel()
            // "When I leave it" marks read on the way out.
            if markRead.mode == .selectionChange { markReadNow() }
        }
        .sheet(item: $composeDraft) { draft in ComposeView(draft: draft) }
        .sheet(isPresented: $showUnlock, onDismiss: { load() }) {
            SealedUnlockSheet { await cloud.thread(conversationId: convo.id, orgId: convo.mxOrgId).stillLocked }
        }
    }

    /// Reply to the latest message's sender (reply-all also keeps its cc). Quotes
    /// the original body, mirroring the desktop reply prefill.
    /// For a domain reply, the from address is the domain address that received the
    /// thread (`convo.toAddress`); the send attaches to the thread via its id.
    private var domainFromEmail: String? {
        ReplyComposer.fromEmailOverride(for: convo, latest: messages.last,
                                        own: ReplyComposer.domainEmails(for: convo, cloud: cloud),
                                        folderReplyAs: AddressFolderStore.shared.replyAs)
    }

    private func replyDraft(all: Bool) -> ComposeDraft {
        let latest = messages.last
        let selfEmail = domainFromEmail ?? engine.accounts.first { $0.id == convo.accountKey }?.email
        var to = ReplyComposer.replyTo(latest, from: selfEmail, fallback: convo.email)
        var cc = ""
        if all {
            let merged = ReplyComposer.replyAllRecipients(latest, selfEmail: selfEmail)
            if !merged.to.isEmpty { to = merged.to }
            cc = merged.cc
        }
        return ComposeDraft(
            fromAccountKey: convo.accountKey,
            conversationId: convo.id,
            fromEmailOverride: domainFromEmail,
            to: to,
            cc: cc,
            subject: ReplyComposer.subjectPrefixed("Re:", convo.subject),
            body: "\n\n\(ReplyComposer.attributedQuote(latest, fallbackSnippet: convo.snippet))",
            replyToMessageKey: latest?.id
        )
    }

    /// Forward the last message, carrying its attachments as *pending* placeholders
    /// (metadata only) — ComposeView downloads the bytes in-screen and blocks Send
    /// until done. Draft construction is shared with the inbox row's Forward.
    private func startForward() {
        guard !preparingForward else { return }
        preparingForward = true
        Task {
            let draft = await ReplyComposer.forwardDraft(for: convo, engine: engine, cloud: cloud)
            await MainActor.run {
                preparingForward = false
                composeDraft = draft
            }
        }
    }

    /// Domain tags: current tags as chips + a menu to toggle the org's tag palette.
    private func snooze(date: Date) {
        Log.action.info("domain snooze \(convo.id, privacy: .public)")
        if let onSnooze { onSnooze(convo, date); return }
        Task {
            let ok = await cloud.snooze(conversationId: convo.id, until: date, orgId: convo.mxOrgId)
            await MainActor.run { if ok { close() } }
        }
    }

    /// Route an action to the cloud (domain) or engine — the shared router on
    /// `EngineModel`. Returns success.
    @discardableResult
    private func perform(_ action: ConversationAction) async -> Bool {
        await engine.perform(accountKey: convo.accountKey, conversationKeys: [convo.id], action: action, cloud: cloud)
    }

    /// Optimistically nudge the app badge for `action` on this thread, so the badge
    /// is correct even if the app backgrounds before the async write-back recompute
    /// runs (`perform` is fired in a detached Task; the reader leaves immediately).
    private func adjustBadge(_ action: ConversationAction) {
        // Once marked read in-session the thread no longer counts as unread, so a
        // following action (e.g. trash) must not decrement the badge a second time.
        AppBadge.adjust(action, convos: [convo]) { $0.unread && !didMarkRead }
    }

    private var sealedBanner: some View {
        let p = theme.palette
        return HStack(spacing: Space.s3) {
            Image(systemName: "lock.fill").font(AppFont.sm).foregroundStyle(p.textTertiary)
            Text("This mail is sealed.").font(AppFont.sm).foregroundStyle(p.textSecondary)
            Spacer()
            PillButton(title: "Unlock", tint: p.accentViolet, minHitHeight: 44) {
                Task { await useSavedKey(orAsk: true) }
            }
        }
        .padding(.horizontal, Space.s4)
    }

    /// Face ID first when a key is saved. If that key no longer opens the grants
    /// (reset identity, removed Face ID), the password sheet replaces it.
    private func useSavedKey(orAsk: Bool) async {
        guard SealedKeychain.hasKey else { if orAsk { showUnlock = true }; return }
        let key = await Task.detached { SealedKeychain.load(reason: "Unlock your key") }.value
        // The key can be fine and this mail still shut: then the password sheet says so.
        if let key, await MxMirror.shared.unlockSealed(identity: key),
           await !cloud.thread(conversationId: convo.id, orgId: convo.mxOrgId).stillLocked {
            load()
        } else if orAsk {
            showUnlock = true
        }
    }

    private func load() {
        // `.task(id: convo.id)` re-runs this on re-navigation; reset the gate so a
        // fresh thread shows the spinner, not the previous thread's resolved state.
        loaded = false
        if convo.isDomain {
            // The thread's tags/assignees/notes are fetched + managed by
            // `DomainCollabSection`; here we only need the messages to render.
            Task {
                let t = await cloud.thread(conversationId: convo.id, orgId: convo.mxOrgId)
                await MainActor.run {
                    messages = t.messages
                    loaded = true
                    sealedLocked = t.sealedLocked
                    if sealedLocked, triedSavedKey != convo.id { triedSavedKey = convo.id; Task { await useSavedKey(orAsk: false) } }
                    scrollToOpenMessage()
                    Log.ui.info("opened domain conversation \(convo.id, privacy: .public) — \(t.messages.count) msg")
                }
            }
        } else {
            Task {
                let msgs = await engine.store.read { $0.messages(conversationKey: convo.id) }
                messages = msgs
                loaded = true
                scrollToOpenMessage()
                Log.ui.info("opened conversation \(convo.id, privacy: .public) — \(msgs.count) message(s)")
            }
        }
        guard convo.unread else { return }
        // Honor the Outlook-style mark-as-read preference.
        switch markRead.mode {
        case .immediate:
            markReadNow()
        case .delay:
            dwellTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(1, markRead.delaySeconds)) * 1_000_000_000)
                if !Task.isCancelled { await MainActor.run { markReadNow() } }
            }
        case .selectionChange, .never:
            break   // selectionChange handled on disappear; never = manual
        }
    }

    /// Queue the open-on-last-message scroll. Only for real threads — a single
    /// message already starts at the top (and we'd otherwise scroll the AI summary
    /// off-screen).
    private func scrollToOpenMessage() {
        guard messages.count > 1, let last = messages.last else { return }
        anchorUntil = Date().addingTimeInterval(anchorWindow)
        anchorID = last.id
    }

    /// How long after opening we keep re-anchoring. Long enough for a body's remote
    /// images to paint (the fit pass re-reports height at 600ms and 1200ms), short
    /// enough that it's over before a reader could deliberately scroll away.
    private var anchorWindow: TimeInterval { 2.5 }

    /// Put the open message's header back at the top. Deferred a runloop so the cards
    /// have laid out at their new heights before the jump.
    private func anchor(_ proxy: ScrollViewProxy) {
        guard let id = anchorID, Date() < anchorUntil else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }

    /// Mark the open conversation read once (idempotent across dwell/disappear).
    private func markReadNow() {
        guard convo.unread, !didMarkRead else { return }
        Log.action.info("mark_read (\(markRead.mode.rawValue, privacy: .public)) \(convo.id, privacy: .public)")
        adjustBadge(.markRead)   // before didMarkRead flips, so it sees the unread state
        didMarkRead = true
        Task { _ = await perform(.markRead) }
    }

    /// The reader's single action path — menu tap, overflow item, or a spoken triage
    /// keyword all land here, so the badge nudge, the dwell cancel and the write-back
    /// can't drift apart per surface. `leave: false` keeps the reader open (triage
    /// quadrants), everything else hands off to `leaveAfter`.
    private func act(_ action: ConversationAction, leave: Bool = true) {
        guard !working else { return }
        Log.action.info("reader action \(action.verb, privacy: .public) on \(convo.id, privacy: .public)")
        working = true
        adjustBadge(action)
        // The thread is leaving the inbox — suppress the dwell / mark-on-leave so it
        // can't double-decrement the badge or fire a redundant mark-read write-back.
        if action.removesRow { dwellTask?.cancel(); didMarkRead = true }
        // Leave the reader immediately and run the durable write-back in the
        // background — don't make the UI sit on the thread for ~1s while the FFI
        // queues the action. The list drops the row optimistically and the store
        // reconciles on the next re-query once the write-back lands (matches the
        // inbox swipe path + the Android reader).
        Task {
            _ = await perform(action)
            await MainActor.run { working = false }
        }
        if leave { leaveAfter(action) }
    }

    /// After a successful destructive action, hand off to the list to advance to
    /// the next conversation; otherwise (no list context) just pop the reader.
    private func leaveAfter(_ action: ConversationAction) {
        if action.removesRow, let onAdvance {
            onAdvance(convo, action)
        } else {
            close()
        }
    }

    /// Answering an invite archives the thread from the inbox (web/desktop do the same);
    /// in archive/sent/trash/spam it stays where it is.
    private var archivesOnRSVP: Bool {
        !folder.hidesArchiveAction && convo.restoreAction == nil && convo.status != ConvStatusValue.archived
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Re-evaluate whether this thread is awaiting (re)summarization: its stored
    /// summaries don't match the latest message (`summariesCurrent`, the same
    /// currency rule the core's email-voice uses) AND the worker queue is live.
    /// Domain threads are summarized server-side — no local indicator.
    private func refreshSummariesProcessing() {
        guard !convo.isDomain else {
            summariesProcessing = false
            return
        }
        Task {
            let stored = await engine.store.read { $0.conversation(key: convo.id) }
            refreshed = stored ?? refreshed
            // Only light the hairline when the worker is actually AT this thread — not
            // merely when it's somewhere in a long backlog queue. The queue is drained
            // newest-first and `currentDate` is the head job's date (== a conversation's
            // updated_at); a pending thread is always at-or-older than the head, so it's
            // the head exactly when its date has caught up to `currentDate`. Mid-backlog
            // threads (worker still on newer mail) stay dark instead of nagging forever.
            let stale = !(stored?.summariesCurrent ?? true)
            let atWorkerHead: Bool = {
                guard let head = engine.triage.currentDate,
                      let mine = RelativeTime.parse(stored?.updatedAt ?? convo.updatedAt) else { return false }
                return mine >= head.addingTimeInterval(-1)
            }()
            let next = engine.triage.isActive && stale && atWorkerHead
            if next != summariesProcessing {
                withAnimation(.easeInOut(duration: 0.3)) { summariesProcessing = next }
            }
        }
    }

    /// A spoken triage keyword landed: same path as the tap, so it nudges the badge
    /// and cancels the dwell mark-read too. Destructive moves leave the reader.
    private func applyVoiceTriage(_ action: ConversationAction) {
        Log.action.info("read-aloud voice triage \(action.verb, privacy: .public) on \(convo.id, privacy: .public)")
        act(action, leave: action.removesRow)
    }

    /// Inspect/compare the stored summaries by reading each aloud. Only the tiers we
    /// actually have for this thread are offered — Small (one-line `aiSummaryShort`),
    /// Medium (few-line `aiSummaryMedium`), Large (the full `aiSummary`) — and "Full
    /// message" reads the latest message verbatim. All speak directly from local data
    /// (no generation / no FFI round-trip).
    @ViewBuilder private var speakWithMenu: some View {
        Menu {
            if let s = current.aiSummaryShort, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { speakSummary(s) } label: { Label("Small", systemImage: "text.alignleft") }
            }
            if let m = current.aiSummaryMedium, !m.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { speakSummary(m) } label: { Label("Medium", systemImage: "text.justify.left") }
            }
            if let l = current.aiSummary, !l.trimmingCharacters(in: .whitespaces).isEmpty {
                Button { speakSummary(l) } label: { Label("Large", systemImage: "text.justify") }
            }
            Divider()
            Button { speakSummary(fullMessageText) } label: { Label("Full message", systemImage: "doc.plaintext") }
            MessageProcessMenu(convo: convo, reprocessing: $reprocessing,
                               reprocessError: $reprocessError, onReprocessed: refreshSummariesProcessing)
        } label: {
            Label("Speak with", systemImage: "speaker.wave.2")
        }
    }

    /// The latest message read verbatim — the plain text representation. The stored "plain"
    /// part often actually carries HTML, so always render it to readable text (drop
    /// style/script, block tags → line breaks, strip remaining tags, decode entities)
    /// before speaking, so no markup is read aloud.
    private var fullMessageText: String {
        let latest = messages.last
        let raw = (latest?.bodyPlain?.isEmpty == false ? latest?.bodyPlain : latest?.bodyHTML) ?? ""
        let text = Self.plainText(from: raw)
        return text.isEmpty ? convo.snippet : text
    }

    /// Strip HTML to readable plain text for the spoken read-out (mirrors the core's
    /// `email_voice::html_to_text`): remove `<style>/<script>/<head>` blocks wholesale,
    /// turn block-level tags into line breaks, drop remaining tags, decode the entities
    /// that matter, and collapse incidental whitespace.
    static func plainText(from raw: String) -> String {
        var s = raw
        for tag in ["script", "style", "head"] {
            s = s.replacingOccurrences(of: "(?is)<\(tag)[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(
            of: "(?i)<(br|/p|/div|/li|/tr|/h[1-6]|/ul|/ol|/blockquote|/section|/article|hr)[^>]*>",
            with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&rsquo;": "'", "&lsquo;": "'", "&ldquo;": "\"",
                        "&rdquo;": "\"", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n[ \\t]*\\n[ \\t]*\\n+", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speak a specific stored summary / body directly (no generation) — the "Speak with"
    /// tester. Cuts any current speech and drives the same playing state as the read-aloud
    /// button (toolbar audio graph + the shared orb).
    private func speakSummary(_ text: String) {
        readAloud.speakPlain(text, convo: convo, engine: engine, voice: voice,
                             speaker: speaker, presence: presence)
    }

    private var moreMenu: some View {
        Menu {
            moreMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(AppFont.lg)
                .foregroundStyle(LinearGradient(colors: p.ringColors, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        // No `.contextMenu` here: it put a second menu interaction on the same
        // control as the `Menu`, and a press-and-hold started both — they took
        // turns presenting and cancelling each other, so the menu flickered.
        // A `Menu` alone already does press → slide onto an item → lift, which is
        // what the context menu was added for.
    }

    @ViewBuilder private var moreMenuItems: some View {
            // Primary message actions (formerly the bottom action bar).
            Button { composeDraft = replyDraft(all: false) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            Button { composeDraft = replyDraft(all: true) } label: { Label("Reply all", systemImage: "arrowshape.turn.up.left.2") }
            Button { startForward() } label: {
                Label(preparingForward ? "Preparing…" : "Forward", systemImage: "arrowshape.turn.up.right")
            }
            .disabled(preparingForward)
            speakWithMenu
            Divider()
            // Destination submenus sit in their own group, above the
            // archive/trash block (mirrors the inbox row menu).
            // Triage quadrants are engine-only (domain uses tags/assignment). inbox2
            // has no flag concept — triage is the move affordance.
            if convo.supportsTriage {
                Menu {
                    ConversationMenus.triageItems(clearIcon: "xmark") { act($0, leave: false) }
                } label: { Label("Move to", systemImage: "tray.and.arrow.down") }
            }
            if convo.supportsSnooze {
                Menu {
                    ConversationMenus.snoozeItems { snooze(date: $0) }
                } label: { Label("Snooze", systemImage: "clock.badge") }
            }
            if convo.supportsTriage || convo.supportsSnooze {
                Divider()
            }
            // Archive / restore / trash grouped together at the bottom. In
            // spam/trash/archived, restoring to the inbox leads; otherwise Archive.
            if let restore = convo.restoreAction {
                Button { act(restore) } label: { Label("Move to Inbox", systemImage: "tray.and.arrow.down") }
            }
            if !folder.hidesArchiveAction && convo.status != ConvStatusValue.archived {
                Button { act(.archive) } label: { Label("Archive", systemImage: "archivebox") }
            }
            // Spam sits above Trash on every channel and stays a plain item — it's a
            // filing move (domain trains Rspamd, offline channels move it to the
            // provider's junk folder), not a delete. Only Trash reads red.
            if convo.status != ConvStatusValue.spam {
                Button { act(.spam) } label: { Label("Mark as spam", systemImage: "exclamationmark.octagon") }
            }
            if !folder.hidesTrashAction && convo.status != ConvStatusValue.trash {
                Button(role: .destructive) { act(.trash) } label: { Label("Trash", systemImage: "trash") }
            }
    }

}
