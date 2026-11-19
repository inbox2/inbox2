import SwiftUI

/// Lore — tab slot 1 (docs/plans/lore.md §6, replaced the Bridge there). What is still
/// open, ranked: a Next-up card, then checklists by bucket. Ticking a box archives the
/// thread through the inbox's own action router (`EngineModel.perform` — local
/// channels and MX alike); swipe does the same. "Handled for you" only suggests.
/// Voice is the floating mic, which opens the Bridge as a sheet.
///
/// Rows come from the same read as the unified inbox (`InboxLoader`, all channels +
/// every MX org's mirrored pool), narrowed to threads with a Lore triage label.
enum LoreTab: String, CaseIterable { case today = "Today", waiting = "Waiting", handled = "Handled", history = "History" }

struct LoreView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    @EnvironmentObject private var voicePresence: VoicePresence
    @EnvironmentObject private var bridgeRouter: BridgeRouter
    /// iPad side panel: the collapse button in the panel's corner. Set means panel, and
    /// the bar stays: hiding it here takes the reader's bar, and its buttons, with it.
    var onCollapse: (() -> Void)? = nil
    @StateObject private var loader = InboxLoader()
    /// Undo for the last tick: the inbox's own toast and five-second window.
    @StateObject private var undoController = InboxUndoController()
    @State private var todos: [LoreTodo] = []
    @State private var navPath = NavigationPath()
    @State private var showBridge = false
    @State private var newTodo = ""
    @State private var refresh = 0
    @State private var expanded: Set<String> = []   // open groups / Handled lists
    // The desktop sidebar's views, as a chip bar (docs/plans/lore.md §3).
    @State private var tab: LoreTab = .today
    @State private var query = ""
    @StateObject private var history = InboxLoader()   // recently archived Lore threads
    @State private var pages: (orgId: String, pages: [LorePageRef])?
    @State private var loaded = false   // the first read finished (no all-clear before it)
    @State private var historyLoaded = false
    @State private var sendTo: Conversation?   // the Send to… sheet's item
    @State private var activityOn = LoreActivityManager.shared.isEnabled   // Next up on the Lock Screen
    @State private var sent: [String: LoreSentRef] = [:]   // what Send to… made, for the row's chip
    @FocusState private var addFocused: Bool

    private var p: ThemePalette { theme.palette }
    private var today: LoreToday { LoreToday.build(loader.conversations.filter { LoreText.matches($0, query) }) }
    /// Archived threads that carried a Lore label, newest first (desktop History).
    private var archived: [Conversation] {
        (history.conversations + loader.conversations.filter { $0.loreDone && !historyIds.contains($0.id) })
            .filter { LoreBucket.forLabel($0.triageLabel) != nil }
            .sorted { (RelativeTime.parse($0.updatedAt) ?? .distantPast) > (RelativeTime.parse($1.updatedAt) ?? .distantPast) }
    }
    /// Open Lore threads (every bucket) — what entity pages draw from.
    private var openLore: [Conversation] { loader.conversations.filter { LoreBucket.forLabel($0.triageLabel) != nil && !$0.loreDone } }
    private var historyIds: Set<String> { Set(history.conversations.map(\.id)) }
    private var reloadKey: String { "\(engine.dataVersion)|\(cloud.revision)|\(refresh)" }

    /// The unified inbox's scope: all channels, Inbox, no filter.
    static let scope = InboxLoader.Scope(
        accountKey: nil, selectedChannel: "", isDomainChannel: false, folder: .inbox,
        filterRaw: InboxFilter.all.rawValue, filter: .all, query: "", pages: 20, labeledOnly: true)
    /// History: local archive + every org's archived pool (100 per org, as web's DONE_LIMIT).
    private static let archiveScope = InboxLoader.Scope(
        accountKey: nil, selectedChannel: "", isDomainChannel: false, folder: .archive,
        filterRaw: InboxFilter.all.rawValue, filter: .all, query: "", pages: 2, labeledOnly: true)

    var body: some View {
        NavigationStack(path: $navPath) {
            content
                // Plain, not the Groovebox grid: a to-do list needs a quiet page.
                .background(p.bgBase.ignoresSafeArea())
                // A tick archives real mail and a stray tap is easy: offer to take it back.
                .overlay(alignment: .top) {
                    if let banner = undoController.banner {
                        undoToast(banner)
                            .padding(.top, Space.s2)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .toolbar(onCollapse == nil ? .hidden : .automatic, for: .navigationBar)
                .toolbar {
                    if let onCollapse {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: onCollapse) {
                                Image(systemName: "sidebar.right").foregroundStyle(p.textSecondary)
                            }
                            .accessibilityLabel("Hide Lore")
                        }
                    }
                }
                .navigationDestination(for: Conversation.self) {
                    // The reader files the thread itself; hand back so the row leaves
                    // Lore at once and the reader pops (no "next thread" here).
                    MessageView(convo: $0, onAdvance: { convo, _ in
                        drop([convo])
                        if !navPath.isEmpty { navPath.removeLast() }
                    })
                }
                .navigationDestination(for: LoreRoute.self) { route in
                    switch route {
                    case .entity(let ref):
                        LoreEntityView(ref: ref, open: openLore, done: archived, onDone: { done($0) })
                    case .page(let orgId, let page):
                        LorePageView(orgId: orgId, page: page)
                    }
                }
                .task(id: reloadKey) { await reload() }
        }
        .overlay(alignment: .bottomTrailing) { if navPath.isEmpty { micButton } }
        .sheet(isPresented: $showBridge, onDismiss: { refresh += 1 }) {
            // The Bridge's own top bar keeps car mode + the game.
            BridgeView()
                .presentationDragIndicator(.visible)
                .onAppear { voicePresence.bridges = 1 }
                .onDisappear { voicePresence.bridges = 0 }
                // Voice drafts open over the Bridge (never sent/saved until the user taps).
                .sheet(item: $bridgeRouter.pendingCompose) { ComposeView(draft: $0) }
                .sheet(item: $bridgeRouter.pendingEvent) { NewEventSheet(seed: $0) }
        }
        .sheet(item: $sendTo) { c in
            SendToSheet(convo: c) { sent[$0.itemKey] = $0 }
                .presentationDragIndicator(.visible)
        }
    }

    private func reload() async {
        await loader.reload(Self.scope, engine: engine, cloud: cloud)
        todos = await engine.loreTodos()
        sent = Dictionary(await McpClient.sent().map { ($0.itemKey, $0) }, uniquingKeysWith: { a, _ in a })   // newest first
        LoreActivityManager.shared.sync(LoreToday.build(loader.conversations))
        loaded = true
        await history.reload(Self.archiveScope, engine: engine, cloud: cloud)
        historyLoaded = true
        pages = await cloud.lorePages()   // nil clears another org's / a signed-out session's titles
    }

    // MARK: - Layout

    private var content: some View {
        let t = today
        let handledCount = t.handled.reduce(0) { $0 + $1.items.count }
        return List {
            header(open: t.open + todos.count)
                .plainListRow()
            tabBar(t, handled: handledCount).plainListRow()
            // A failed local read shows on every view: its work is missing from all of them.
            if let error = (tab == .history ? history.loadError : nil) ?? loader.loadError { errorBanner(error) }

            if (tab == .history ? !historyLoaded : !loaded) && tab != .today {
                // Each view's data isn't in yet: no "nothing here" before it is.
                ProgressView().frame(maxWidth: .infinity, minHeight: 240).plainListRow()
            } else {
            switch tab {
            case .today: todayBody(t, handledCount: handledCount)
            case .waiting:
                let waiting = t.sections.first { $0.bucket == .waiting }?.groups ?? []
                group("Waiting on others", tint: tint(.waiting), groups: waiting)
                if waiting.isEmpty && loader.loadError == nil { muted("Nothing waiting — no one owes you an answer.") }
            case .handled:
                if handledCount > 0 { handledGroup(t.handled) } else if loader.loadError == nil { muted("Nothing to review.") }
            case .history: historyBody
            }
            }

            Color.clear.frame(height: 120).plainListRow()   // clear the nav + mic
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            engine.sync()
            refresh += 1
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    @ViewBuilder
    private func todayBody(_ t: LoreToday, handledCount: Int) -> some View {
            if !query.isEmpty { searchHits }
            if let next = nextGroup(t) {
                nextUpCard(next)
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s4)
                    .plainListRow()
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240).plainListRow()
            } else if loader.loadError != nil {
                EmptyView()
            } else if !query.isEmpty && !hasEntityHits && handledCount == 0 {
                // Filtered to nothing: say so, not "nothing on your plate".
                EmptyState(systemImage: "magnifyingglass", title: "No results",
                           message: "Nothing in Lore matches \u{201C}\(query)\u{201D}.")
                    .frame(minHeight: 240)
                    .plainListRow()
            } else if handledCount == 0 && todos.isEmpty {
                EmptyState(systemImage: "checkmark.circle", title: "Nothing on your plate",
                           message: "New mail is sorted here as Jev triages it. Ask the mic to remind you of anything else.")
                    .background(Color.clear)
                    .frame(minHeight: 320)
                    .plainListRow()
            }

            // The top "Do first" item is the Next-up card, so the group starts after it.
            let nextId = nextGroup(t)?.id
            group("Do first", tint: p.accentViolet, groups: t.firstGroups.filter { $0.id != nextId })
            if query.isEmpty { orgsStrip }
            ForEach(t.sections) { s in
                group(s.title, tint: tint(s.bucket), groups: s.groups.filter { $0.id != nextId })
            }
            if query.isEmpty { todosGroup }
            if handledCount > 0 { handledGroup(t.handled) }
            if query.isEmpty { pagesGroup }
    }

    // MARK: - Views, search, orgs, pages, history

    private func tabBar(_ t: LoreToday, handled: Int) -> some View {
        let waiting = t.sections.first { $0.bucket == .waiting }?.items.count ?? 0
        return VStack(spacing: Space.s2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s2) {
                    ForEach(LoreTab.allCases, id: \.self) { v in
                        let count = v == .waiting ? waiting : v == .handled ? handled : 0
                        Button {
                            withAnimation(.snappy) {
                                tab = v
                                // The Handled view opens with every group unfolded; each still collapses.
                                if v == .handled { expanded.formUnion(LoreHandledGroup.order.map { "handled:\($0.id)" }) }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(v.rawValue).font(AppFont.sm(.semibold))
                                if count > 0 { Text("\(count)").font(AppFont.xs2).foregroundStyle(p.textTertiary) }
                            }
                            .foregroundStyle(tab == v ? p.textPrimary : p.textSecondary)
                            .padding(.horizontal, Space.s3)
                            .frame(minHeight: 34)
                            .background(Capsule().fill(tab == v ? p.bgRaised : Color.clear))
                            .overlay(Capsule().stroke(tab == v ? p.borderDefault : p.borderSubtle, lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tab == v ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Space.s4)
            }
            HStack(spacing: Space.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(p.textTertiary)
                TextField(tab == .history ? "Filter history" : "Search Lore — mail, people, pages", text: $query)
                    .font(AppFont.sm)
                    .foregroundStyle(p.textPrimary)
                    .submitLabel(.search)
                    .onChange(of: query) { _, q in if !q.isEmpty && tab != .today && tab != .history { tab = .today } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(p.textTertiary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Space.s3)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(p.bgRaised))
            .padding(.horizontal, Space.s4)
        }
        .padding(.bottom, Space.s3)
    }

    /// Organizations behind the open work, most threads first (the desktop sidebar's list).
    private var orgs: [(domain: String, count: Int)] {
        var by: [String: Int] = [:]
        for c in openLore { if let d = LoreText.orgDomain(c.email) { by[d, default: 0] += 1 } }
        return by.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    @ViewBuilder private var orgsStrip: some View {
        let top = Array(orgs.prefix(12))
        if !top.isEmpty {
            groupHeader("Organizations", tint: p.accentPrimary, count: orgs.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s2) {
                    ForEach(top, id: \.domain) { o in
                        NavigationLink(value: LoreRoute.entity(.org(domain: o.domain))) {
                            HStack(spacing: Space.s2) {
                                LoreLogo(domain: o.domain, size: 22)
                                Text(LoreText.domainLabel(o.domain)).font(AppFont.sm).foregroundStyle(p.textPrimary)
                                Text("\(o.count)").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                            }
                            .padding(.horizontal, Space.s3)
                            .frame(minHeight: 40)
                            .background(Capsule().fill(p.bgRaised))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Space.s4)
            }
            .plainListRow()
        }
    }

    @ViewBuilder private var pagesGroup: some View {
        if let pages, !pages.pages.isEmpty {
            groupHeader("Pages", tint: p.accentTeal, count: pages.pages.count)
            ForEach(pages.pages) { page in pageRow(pages.orgId, page) }
        }
    }

    private func pageRow(_ orgId: String, _ page: LorePageRef) -> some View {
        NavigationLink(value: LoreRoute.page(orgId: orgId, page: page)) {
            Label(page.name, systemImage: "doc.text").font(AppFont.base).foregroundStyle(p.textPrimary)
                .frame(minHeight: 40)
        }
        .padding(.horizontal, Space.s4)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(p.borderSubtle)
    }

    /// Does the search match any organization, person or page (so "No results" would be wrong)?
    private var hasEntityHits: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return orgs.contains { $0.domain.localizedCaseInsensitiveContains(q) }
            || LoreEntityView.people(in: openLore + archived).contains {
                $0.name.localizedCaseInsensitiveContains(q) || $0.address.localizedCaseInsensitiveContains(q) }
            || (pages?.pages ?? []).contains { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Search's non-mail hits: organizations, people and pages whose name matches.
    @ViewBuilder private var searchHits: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let orgHits = orgs.filter { $0.domain.localizedCaseInsensitiveContains(q) }.prefix(8)
        let people = LoreEntityView.people(in: openLore + archived)
            .filter { $0.name.localizedCaseInsensitiveContains(q) || $0.address.localizedCaseInsensitiveContains(q) }.prefix(8)
        let pageHits = (pages?.pages ?? []).filter { $0.name.localizedCaseInsensitiveContains(q) }
        if !orgHits.isEmpty || !people.isEmpty {
            groupHeader("Organizations & people", tint: p.accentPrimary, count: orgHits.count + people.count)
            ForEach(Array(orgHits), id: \.domain) { o in
                entityLink(.org(domain: o.domain), title: LoreText.domainLabel(o.domain), detail: o.domain, icon: "building.2", logo: o.domain)
            }
            ForEach(Array(people), id: \.address) { person in
                entityLink(.person(address: person.address, name: person.name), title: person.name, detail: person.address, icon: "person")
            }
        }
        if let pages, !pageHits.isEmpty {
            groupHeader("Pages", tint: p.accentTeal, count: pageHits.count)
            ForEach(pageHits) { page in pageRow(pages.orgId, page) }
        }
    }

    private func entityLink(_ ref: LoreEntityRef, title: String, detail: String, icon: String, logo: String? = nil) -> some View {
        NavigationLink(value: LoreRoute.entity(ref)) {
            HStack(spacing: Space.s3) {
                if let logo { LoreLogo(domain: logo, size: 20) } else { Image(systemName: icon).foregroundStyle(p.textTertiary).frame(width: 20) }
                Text(title).font(AppFont.base).foregroundStyle(p.textPrimary)
                Text(detail).font(AppFont.xs2).foregroundStyle(p.textTertiary).lineLimit(1)
            }
            .frame(minHeight: 40)
        }
        .padding(.horizontal, Space.s4)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// Recently archived Lore threads; "Put back" returns one to the inbox and Today.
    @ViewBuilder private var historyBody: some View {
        let rows = Array(archived.filter { LoreText.matches($0, query) }.prefix(100))
        groupHeader("History", tint: p.textMuted, count: rows.count)
        if rows.isEmpty && history.loadError == nil && loader.loadError == nil { muted("Nothing here yet.") }
        ForEach(rows) { c in
            HStack(spacing: Space.s2) {
                Button { navPath.append(c) } label: {
                    HStack(spacing: Space.s2) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(p.accentSuccess)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(c)).font(AppFont.base).foregroundStyle(p.textPrimary).lineLimit(1)
                            Text("\(c.sender) · \(c.time)").font(AppFont.xs2).foregroundStyle(p.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                PillButton(title: "Put back", tint: p.accentViolet, style: .outlined, minHitHeight: 44) { putBack(c) }
            }
            .padding(.horizontal, Space.s4)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(p.borderSubtle)
        }
    }

    private func putBack(_ c: Conversation) {
        if c.loreDone {
            setLoreDone([c.id], false)
            Task { _ = await engine.perform(accountKey: c.accountKey, conversationKeys: [c.id], action: .loreUndone, cloud: cloud); refresh += 1 }
            return
        }
        withAnimation { history.conversations.removeAll { $0.id == c.id } }
        history.pendingRemoved.insert(c.id)
        Task {
            let ok = await engine.perform(accountKey: c.accountKey, conversationKeys: [c.id], action: .unarchive, cloud: cloud)
            if !ok { history.pendingRemoved.remove(c.id) }
            refresh += 1
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(p.accentDanger)
            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t load the mail on this phone").font(AppFont.sm(.semibold)).foregroundStyle(p.textPrimary)
                Text("Some work may be missing. \(error)").font(AppFont.xs).foregroundStyle(p.textTertiary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Try again") { refresh += 1 }
                .font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet).frame(minHeight: 44)
        }
        .padding(Space.s3)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(p.accentDanger.opacity(0.1)))
        .padding(.horizontal, Space.s4)
        .padding(.bottom, Space.s3)
        .plainListRow()
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(AppFont.sm).foregroundStyle(p.textTertiary)
            .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
            .plainListRow()
    }

    private func header(open: Int) -> some View {
        HStack(spacing: Space.s2 + 2) {
            Text("Lore")
                .font(AppFont.title.smallCaps())
                .foregroundStyle(p.textSecondary)
            if open > 0 {
                Text("(\(open))")
                    .font(AppFont.title2)
                    .foregroundStyle(p.textSecondary.opacity(0.7))
            }
            Spacer()
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s3)
    }

    /// The Next-up card's group: the top "Do first" entry, else the first section's.
    private func nextGroup(_ t: LoreToday) -> LoreGroup? {
        t.firstGroups.first ?? t.sections.lazy.compactMap(\.groups.first).first
    }

    private func title(_ c: Conversation) -> String {
        let t = LoreText.clean(c.subject)
        return t.isEmpty ? (c.subject.isEmpty ? "(no subject)" : c.subject) : t
    }

    private func nextUpCard(_ g: LoreGroup) -> some View {
        let c = g.lead
        let bucket = LoreBucket.forLabel(c.triageLabel) ?? .work
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Text("NEXT UP")
                    .font(AppFont.xs3(.bold))
                    .foregroundStyle(LinearGradient(colors: p.ringColors, startPoint: .leading, endPoint: .trailing))
                tag(bucket, c)
                Spacer()
                Text(c.time).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                Button {
                    activityOn.toggle()
                    LoreActivityManager.shared.isEnabled = activityOn
                    LoreActivityManager.shared.sync(LoreToday.build(loader.conversations))
                } label: {
                    Image(systemName: activityOn ? "lock.fill" : "lock")
                        .font(AppFont.xs2)
                        .foregroundStyle(activityOn ? p.accentViolet : p.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(activityOn ? "Remove Next up from the Lock Screen" : "Show Next up on the Lock Screen")
            }
            Text(title(c))
                .font(AppFont.lg)
                .foregroundStyle(p.textPrimary)
                .lineLimit(2)
            Text(c.preview)
                .font(AppFont.sm)
                .foregroundStyle(p.textSecondary)
                .lineLimit(3)
            Text(c.sender).font(AppFont.xs2).foregroundStyle(p.textTertiary)
            if g.items.count > 1 {
                // "Done (N)" acts on every email: let them be seen first.
                Button { toggle(g.id) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right").font(AppFont.xs3(.semibold))
                            .rotationEffect(.degrees(expanded.contains(g.id) ? 90 : 0))
                        Text("\(g.items.count) emails").font(AppFont.xs2(.semibold))
                    }
                    .foregroundStyle(p.textSecondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded.contains(g.id) ? "Hide the emails" : "Show the \(g.items.count) emails")
                if expanded.contains(g.id) {
                    ForEach(g.items.dropFirst()) { other in
                        Button { navPath.append(other) } label: {
                            HStack {
                                Text(title(other)).font(AppFont.sm).foregroundStyle(p.textPrimary).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(other.time).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: Space.s3) {
                Button { navPath.append(c) } label: {
                    Label(bucket == .reply ? "Open & reply" : "Open email",
                          systemImage: bucket == .reply ? "arrowshape.turn.up.left" : "envelope.open")
                        .font(AppFont.sm(.semibold))
                        .foregroundStyle(p.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(LinearGradient(colors: p.ringColors, startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(PressableStyle())
                Button { done(g.items) } label: {
                    Label(g.items.count > 1 ? "Done (\(g.items.count))" : "Done", systemImage: "checkmark")
                        .font(AppFont.sm(.semibold))
                        .foregroundStyle(p.textPrimary)
                        .frame(minWidth: 96, minHeight: 44)
                        .background(Capsule().fill(p.bgRaised))
                        .overlay(Capsule().stroke(p.borderDefault, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.top, Space.s1)
        }
        .padding(Space.s4)
        .background(RoundedRectangle(cornerRadius: p.panelRadius ?? Radius.xl, style: .continuous).fill(p.bgPanel))
        .overlay(RoundedRectangle(cornerRadius: p.panelRadius ?? Radius.xl, style: .continuous).stroke(p.borderSubtle, lineWidth: 1))
    }

    @ViewBuilder
    private func group(_ title: String, tint: Color, groups: [LoreGroup]) -> some View {
        if !groups.isEmpty {
            groupHeader(title, tint: tint, count: groups.reduce(0) { $0 + $1.items.count })
            ForEach(groups) { g in
                row(g.lead, tint: tint, group: g)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { done(g.items) } label: { Label("Done", systemImage: "checkmark") }
                            .tint(p.accentSuccess)
                    }
                if g.items.count > 1 && expanded.contains(g.id) {
                    ForEach(g.items.dropFirst()) { c in   // the lead is the row above
                        row(c, tint: nil, group: nil)
                            .padding(.leading, Space.s6)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { done([c]) } label: { Label("Done", systemImage: "checkmark") }
                                    .tint(p.accentSuccess)
                            }
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy) { if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
    }

    /// The section's colour in the gutter; older mail, fainter bar (web `ageStep`).
    private func ageBar(_ c: Conversation, _ tint: Color?) -> some View {
        let fade: [Double] = [1, 0.75, 0.5, 0.35, 0.2]
        return RoundedRectangle(cornerRadius: 1.5)
            .fill((tint ?? .clear).opacity(fade[LoreText.ageStep(c)]))
            .frame(width: 3)
            .padding(.vertical, Space.s2)
            .accessibilityHidden(true)
    }

    private func groupHeader(_ title: String, tint: Color, count: Int) -> some View {
        HStack(spacing: Space.s2) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title).font(AppFont.section(13)).foregroundStyle(p.textSecondary)
            Text("\(count)").font(AppFont.xs2).foregroundStyle(p.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s4)
        .padding(.bottom, Space.s1)
        .plainListRow()
    }

    /// A to-do row. `group` (2+ threads) makes it stand for all of them: ticking
    /// archives every one, and the "N emails" chip unfolds the list.
    private func row(_ c: Conversation, tint: Color?, group: LoreGroup?, action: ConversationAction = .archive) -> some View {
        let many = (group?.items.count ?? 0) > 1
        return HStack(alignment: .top, spacing: Space.s1) {
            ageBar(c, tint)
            checkbox(label: c.subject) { done(group?.items ?? [c], action) }   // Handled rows carry their group's action (delete for codes)
            VStack(alignment: .trailing, spacing: 0) {
            Button { navPath.append(c) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s2) {
                        Text(title(c))
                            .font(AppFont.base(c.unread ? .semibold : .regular))
                            .foregroundStyle(p.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(c.time).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    }
                    Text(c.preview).font(AppFont.xs).foregroundStyle(p.textSecondary).lineLimit(2)
                    HStack(spacing: Space.s1) {
                        if let domain = LoreText.orgDomain(c.email) { LoreLogo(domain: domain, size: 14) }
                        // A personal-address sender (gmail.com…) is a person: their initials.
                        else { Avatar(initials: c.initials, size: 14, seed: c.seed) }
                        Text(c.sender).font(AppFont.xs2).foregroundStyle(p.textTertiary).lineLimit(1)
                        if let ref = sent[LoreSentRef.key(for: c)] { sentChip(ref) }
                    }
                }
                .padding(.vertical, Space.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
                // Its own row under the open button (a sibling, not an overlay on it),
                // so unfolding the group can never also open the lead email.
                if many, let group {
                    Button { toggle(group.id) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.right")
                                .font(AppFont.xs3(.semibold))
                                .rotationEffect(.degrees(expanded.contains(group.id) ? 90 : 0))
                            Text("\(group.items.count) emails").font(AppFont.xs3(.semibold))
                        }
                        .foregroundStyle(p.textSecondary)
                        .padding(.horizontal, Space.s2)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(p.bgRaised))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded.contains(group.id) ? "Hide the emails" : "Show the \(group.items.count) emails")
                    .padding(.bottom, Space.s2)
                }
            }
        }
        .padding(.trailing, Space.s4)
        .padding(.leading, Space.s1)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(p.borderSubtle)
        // Long-press: the sender's Lore pages (the desktop's @mentions) and Send to….
        .contextMenu {
            Button { sendTo = c } label: { Label("Send to…", systemImage: "paperplane") }
            if let domain = LoreText.orgDomain(c.email) {
                Button { navPath.append(LoreRoute.entity(.org(domain: domain))) } label: {
                    Label("Open \(LoreText.domainLabel(domain))", systemImage: "building.2")
                }
            }
            if !c.email.isEmpty {
                Button { navPath.append(LoreRoute.entity(.person(address: c.email.lowercased(), name: c.sender))) } label: {
                    Label("Open \(c.sender)", systemImage: "person")
                }
            }
        }
    }

    /// The chip Send to… left on the row. The link opens only from this tap.
    @ViewBuilder private func sentChip(_ ref: LoreSentRef) -> some View {
        let chip = HStack(spacing: 3) {
            Image(systemName: "paperplane").font(AppFont.xs3)
            Text(ref.chipLabel).font(AppFont.xs3(.semibold))
        }
        .foregroundStyle(p.textSecondary)
        .padding(.horizontal, Space.s2)
        .padding(.vertical, 2)
        .background(Capsule().fill(p.bgRaised))
        if let raw = ref.url, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? "") {
            Link(destination: url) { chip }.buttonStyle(.plain)
        } else {
            chip
        }
    }

    /// A real ≥44pt checkbox: the ring is 22pt, the hit target the full 44.
    private func checkbox(label: String, checked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(p.borderStrong, lineWidth: 1.5).frame(width: 22, height: 22)
                if checked { Image(systemName: "checkmark").font(AppFont.xs2(.bold)).foregroundStyle(p.accentSuccess) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mark done: \(label)")
    }

    private func tag(_ bucket: LoreBucket, _ c: Conversation) -> some View {
        let text = c.triage == nil
            ? TriageLabelNames.name(for: c.triageLabel ?? "", orgId: c.isDomain ? c.accountKey : nil)
            : bucket.tag
        return Text(text)
            .font(AppFont.xs3(.semibold))
            .foregroundStyle(tint(bucket))
            .padding(.horizontal, Space.s2)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint(bucket).opacity(0.14)))
    }

    // MARK: - My todos

    @ViewBuilder private var todosGroup: some View {
        groupHeader("My todos", tint: p.accentTeal, count: todos.count)
        ForEach(todos) { todo in
            HStack(spacing: Space.s1) {
                checkbox(label: todo.title) { complete(todo) }
                Text(todo.title).font(AppFont.base).foregroundStyle(p.textPrimary)
                Spacer()
                if todo.source == "voice" {
                    Image(systemName: "mic").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                        .accessibilityLabel("Added by voice")
                }
            }
            .padding(.trailing, Space.s4)
            .padding(.leading, Space.s1)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(p.borderSubtle)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { complete(todo) } label: { Label("Done", systemImage: "checkmark") }
                    .tint(p.accentSuccess)
            }
        }
        HStack(spacing: Space.s1) {
            Image(systemName: "plus")
                .font(AppFont.sm(.semibold))
                .foregroundStyle(p.textTertiary)
                .frame(width: 44, height: 44)
            TextField("Add todo", text: $newTodo)
                .font(AppFont.base)
                .foregroundStyle(p.textPrimary)
                .focused($addFocused)
                .submitLabel(.done)
                .onSubmit(addTodo)
                .frame(minHeight: 44)
        }
        .padding(.trailing, Space.s4)
        .padding(.leading, Space.s1)
        .plainListRow()
    }

    private func addTodo() {
        let title = newTodo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        newTodo = ""
        Task { if await engine.addLoreTodo(title) { todos = await engine.loreTodos() } }
    }

    private func complete(_ todo: LoreTodo) {
        withAnimation { todos.removeAll { $0.id == todo.id } }
        Task { await engine.completeLoreTodo(todo.id) }
    }

    // MARK: - Handled for you

    @ViewBuilder
    private func handledGroup(_ groups: [LoreHandledGroup]) -> some View {
        groupHeader("Handled for you — waiting for your OK", tint: p.textMuted,
                    count: groups.reduce(0) { $0 + $1.items.count })
        ForEach(groups.filter { !$0.items.isEmpty }) { g in
            let key = "handled:\(g.id)"
            HStack(spacing: Space.s3) {
                // Tap to see which threads these are before acting on them.
                Button { toggle(key) } label: {
                    HStack(spacing: Space.s2) {
                        Image(systemName: "chevron.right")
                            .font(AppFont.xs2(.semibold))
                            .rotationEffect(.degrees(expanded.contains(key) ? 90 : 0))
                        Text("\(g.items.count) \(g.title.lowercased())")
                            .font(AppFont.sm)
                    }
                    .foregroundStyle(p.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded.contains(key) ? "Hide the \(g.title)" : "Show the \(g.items.count) \(g.title)")
                PillButton(title: "\(g.buttonLabel) \(g.items.count)",
                           tint: g.action == .trash ? p.accentDanger : p.accentViolet,
                           style: .outlined, minHitHeight: 44) { done(g.items, g.action) }
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, Space.s4)
            .plainListRow()
            if expanded.contains(key) {
                ForEach(g.items) { c in
                    row(c, tint: nil, group: nil, action: g.action)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { done([c], g.action) } label: { Label(g.button, systemImage: "checkmark") }
                                .tint(g.action == .trash ? p.accentDanger : p.accentSuccess)
                        }
                }
            }
        }
    }

    // MARK: - Actions

    private func undoToast(_ banner: UndoBanner) -> some View {
        let subject = banner.primary?.subject.isEmpty == false ? banner.primary!.subject : "(No subject)"
        return ToastRow(icon: banner.action.icon, title: banner.action.title,
                        subtitle: banner.count > 1 ? "\(banner.count) conversations" : subject) {
            Button("Undo") { undoDone(banner) }
                .font(AppFont.sm(.semibold))
                .foregroundStyle(p.accentViolet)
        }
    }

    /// Take the last tick back: stop hiding the rows, restore the badge, reverse the
    /// write-back, and re-read so they return in their places.
    private func undoDone(_ banner: UndoBanner) {
        if let reverse = banner.reverse { AppBadge.adjust(reverse, convos: banner.items.map(\.convo)) }
        undoController.undo(engine: engine, cloud: cloud) { item in
            loader.pendingRemoved.remove(item.convo.id)
            if item.reverse != nil { setLoreDone([item.convo.id], false) }
        }
        refresh += 1
    }

    /// Drop rows from Lore now and keep them out of re-queries until the write-back lands.
    private func drop(_ convos: [Conversation]) {
        let ids = Set(convos.map(\.id))
        withAnimation { loader.conversations.removeAll { ids.contains($0.id) } }
        loader.pendingRemoved.formUnion(ids)
    }

    /// Flip the per-member tick on rows the list still holds (they stay in the inbox read).
    private func setLoreDone(_ ids: Set<String>, _ done: Bool) {
        withAnimation {
            for i in loader.conversations.indices where ids.contains(loader.conversations[i].id) {
                loader.conversations[i].loreDone = done
            }
        }
    }

    /// Done = archive (or the Handled group's action), through the inbox's router —
    /// one call per account, as the inbox's bulk bar does. A personal bucket on a shared
    /// domain is this member's tick instead, and the thread stays in the inbox.
    private func done(_ convos: [Conversation], _ action: ConversationAction = .archive) {
        guard !convos.isEmpty else { return }
        let mine = convos.filter(\.isMemberDone), rest = convos.filter { !$0.isMemberDone }
        setLoreDone(Set(mine.map(\.id)), true)
        drop(rest)
        AppBadge.adjust(action, convos: rest)
        let shown = rest.isEmpty ? ConversationAction.loreDone : action
        if let reverse = shown.reverse {
            undoController.show(UndoBanner(items: convos.enumerated().map {
                .init(convo: $1, index: $0, reverse: $1.isMemberDone ? .loreUndone : nil)
            }, action: shown, reverse: reverse))
        }
        for (acct, group) in Dictionary(grouping: mine, by: \.accountKey) {
            let keys = group.map(\.id)
            Task {
                guard !(await engine.perform(accountKey: acct, conversationKeys: keys, action: .loreDone, cloud: cloud)) else { return }
                setLoreDone(Set(keys), false)
                refresh += 1
            }
        }
        for (acct, group) in Dictionary(grouping: rest, by: \.accountKey) {
            let keys = group.map(\.id)
            Task {
                guard !(await engine.perform(accountKey: acct, conversationKeys: keys, action: action, cloud: cloud)) else { return }
                // Refused: stop hiding the rows, take back the badge move, re-read.
                loader.pendingRemoved.subtract(keys)
                let delta = { (rows: [Conversation]) in rows.reduce(0) { $0 + action.badgeDelta(wasUnread: $1.unread) } }
                AppBadge.adjustChannel(by: -delta(group.filter { !$0.isDomain }))
                AppBadge.adjustDomain(by: -delta(group.filter(\.isDomain)))
                refresh += 1
            }
        }
    }

    private func tint(_ bucket: LoreBucket) -> Color {
        switch bucket {
        case .pay: return p.accentAmber
        case .reply: return p.accentViolet
        case .work: return p.accentPrimary
        case .meet: return p.accentTeal
        case .review: return p.accentPurple
        case .read: return p.textTertiary
        case .waiting: return p.statusPending
        case .handled: return p.textMuted
        }
    }

    // MARK: - Voice

    /// Voice is secondary now: the mic opens the Bridge (brief + push-to-talk) as a sheet.
    private var micButton: some View {
        Button { showBridge = true } label: {
            // The Bridge's voice blob, small and idling (heartbeat) — tap to talk.
            VoiceOrb(size: 34)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .padding(.trailing, Space.s4)
        .padding(.bottom, 86)   // above the floating nav
        .accessibilityLabel("Talk to the Bridge")
    }
}
