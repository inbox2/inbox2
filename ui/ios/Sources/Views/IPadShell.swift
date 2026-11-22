import SwiftUI

/// The thread open in the iPad reader column, plus the list's handlers for what a
/// destructive action there does (file the row, advance to its neighbour).
@MainActor final class SplitReader: ObservableObject {
    @Published var convo: Conversation?
    /// The inbox's selected channel chip label ("Unified", an email, a domain).
    @Published var channelLabel = "Unified"
    /// The chip itself, so a list that remounts (portrait sidebar pages) keeps it.
    var channel = "unified"
    var folder: MailFolder = .inbox
    /// Published so the reader picks up a remounted list's handlers; nil while no list
    /// is mounted (iPad portrait, sidebar on the folder page).
    @Published var onAdvance: ((Conversation, ConversationAction) -> Void)?
    @Published var onSnooze: ((Conversation, Date) -> Void)?
    /// Which list instance bound the handlers, so a list leaving after its successor
    /// mounted (rotation) doesn't clear the new list's handlers.
    var owner: UUID?
}

/// iPad (regular width) layout, modelled on desktop: a sidebar of sections and
/// folders, the unified inbox list, the reader, and Lore as a toggleable side panel.
/// `selection` is RootTabs' tab index (0 Inbox, 1 Lore, 2 Calendar, 3 Settings), so
/// the shell's routing (notification taps, calendar jumps) works unchanged.
struct IPadShell: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var chrome: ChromeModel
    @Binding var selection: Int
    @Binding var selectedFolder: MailFolder
    @Binding var activeProvider: String?
    var onCompose: () -> Void
    @StateObject private var split = SplitReader()
    @ObservedObject private var addressFolders = AddressFolderStore.shared
    // A tapped new-mail notification needs the list mounted (portrait: pushed).
    @ObservedObject private var notifications = NotificationManager.shared
    /// Landscape: the folder column hidden (list + reader only). Remembered.
    @AppStorage("ipad.foldersHidden") private var foldersHidden = false
    /// Sidebar drill-down: empty = sections, then the inbox's folders, then (portrait
    /// only) the message list — one navigation stack, like Mail on an upright iPad.
    @State private var sidebarPath: [String] = []
    private static let listPage = "list"
    @State private var showSettings = false
    /// Portrait Inbox stacks the message list on top of the sidebar.
    private var inboxPath: [String] { wide ? [] : [Self.listPage] }
    private func landingPath(_ tab: Int) -> [String] { tab == 0 ? inboxPath : [] }
    /// Sidebar row / ⌘1–4: switch section (Settings is a sheet, not a section).
    private func go(_ tab: Int) {
        if tab == 3 { showSettings = true }
        else if selection == tab { sidebarPath = landingPath(tab) }
        else { selection = tab }
    }
    /// The persisted Lore-panel choice applies only where four panes fit (≥1300pt —
    /// 12.9"/13" landscape); narrower layouts start with it closed so the reader keeps room.
    @AppStorage("ipad.lorePanel") private var loreRoomy = true
    @State private var loreTight = false
    /// ≥1100pt: list gets its own column. ≥1300pt: room for Lore beside the reader too.
    @State private var wide = true
    @State private var roomy = true

    private var showLore: Bool { roomy ? loreRoomy : loreTight }
    private var loreBinding: Binding<Bool> {
        Binding(get: { showLore }, set: { if roomy { loreRoomy = $0 } else { loreTight = $0 } })
    }

    private var p: ThemePalette { theme.palette }

    private let sections = [
        (icon: "envelope", label: "Mail"),
        (icon: "checklist", label: "Lore"),
        (icon: "calendar", label: "Calendar"),
        (icon: "gearshape", label: "Settings"),
    ]

    var body: some View {
        shell
            .sheet(isPresented: $showSettings) { SettingsView(onClose: { showSettings = false }) }
            // Landscape shows the list as its own column; portrait stacks it in the sidebar.
            // The path moves in the same update as the width, so a rotation never draws
            // the other layout's page first.
            .onGeometryChange(for: Bool.self) { $0.size.width >= 1100 } action: { w in
                wide = w
                if selection == 0 { sidebarPath = inboxPath }
            }
            .onGeometryChange(for: Bool.self) { $0.size.width >= 1300 } action: { roomy = $0 }
            // A jump from elsewhere (notification, zone card → Calendar) must leave the
            // folder page, or the sidebar shows Inbox folders over another section.
            // Shortcuts live here, not on sidebar rows: the root page isn't mounted
            // while the folder page is pushed.
            .background {
                Group {
                    Button("", action: onCompose).keyboardShortcut("n", modifiers: .command)
                    // Mail only: the panel exists nowhere else.
                    if selection == 0 {
                        Button("") { withAnimation { loreBinding.wrappedValue.toggle() } }
                            .keyboardShortcut("l", modifiers: [.command, .shift])
                    }
                    ForEach(sections.indices, id: \.self) { i in
                        Button("") { go(i) }
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    }
                }
                .hidden()
            }
            // A section switch swaps split views, which rebuilds the sidebar stack:
            // land on its root, then push the section's page once that is up, so the
            // push animates (tap, ⌘-key, or a jump from elsewhere alike).
            .onChange(of: selection) { _, tab in
                sidebarPath = []
                let land = landingPath(tab)
                if !land.isEmpty { DispatchQueue.main.async { sidebarPath = land } }
            }
            .onChange(of: notifications.pendingConversationKey) { _, key in
                if key != nil { sidebarPath = inboxPath }
            }
            // "Search mail" from the reader: the list owns search, so bring it back.
            .onChange(of: chrome.pendingSearch) { _, value in
                // Like the phone, which pops the thread to show the results.
                if value != nil { selection = 0; sidebarPath = inboxPath; split.convo = nil }
            }
    }

    @ViewBuilder private var shell: some View {
        // One split view per section, whatever the width: iPadOS re-lays the window out
        // in another orientation for its App Switcher snapshot, and swapping or nesting
        // split views during that pass aborted inside UIKit (TestFlight crash,
        // 2026-11-08). Width only rearranges what is inside the sidebar column.
        if selection == 0 {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                sidebar
            } detail: {
                readerWithLore
            }
            .navigationSplitViewStyle(.balanced)
            // A folder or account switch leaves the open thread behind.
            .onChange(of: selectedFolder) { _, _ in split.convo = nil }
            .onChange(of: addressFolders.selected) { _, _ in split.convo = nil }
        } else {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                sidebar
            } detail: {
                switch selection {
                case 1: LoreView()
                case 2: CalendarView()
                default: SettingsView()
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    private func inboxList(onBack: (() -> Void)?, onShowFolders: (() -> Void)? = nil,
                           underStatusBar: Bool = false) -> some View {
        InboxListView(selectedFolder: $selectedFolder, showFolders: .constant(false),
                      activeProvider: $activeProvider, split: split,
                      splitSelectedId: split.convo?.id, onBack: onBack, onShowFolders: onShowFolders,
                      underStatusBar: underStatusBar)
    }

    /// Lore is a plain view beside the reader, not an `.inspector`: see `shell`.
    private var readerWithLore: some View {
        HStack(spacing: 0) {
            reader.frame(maxWidth: .infinity)
            if showLore {
                edgeLine.frame(width: 1).ignoresSafeArea()
                LoreView(onCollapse: { withAnimation { loreBinding.wrappedValue = false } })
                    .frame(width: 340).transition(.move(edge: .trailing))
            }
        }
    }

    @ViewBuilder private var reader: some View {
        if let convo = split.convo {
            // The detail column is already a navigation context (title bar + toolbar).
            // With no list mounted (portrait, folder page) the handlers are nil and the
            // reader files the thread itself, then clears the column.
            MessageView(convo: convo, folder: split.folder, onAdvance: split.onAdvance,
                        onSnooze: split.onSnooze, embedded: true,
                        onClose: { split.convo = nil })
                .toolbar { loreToggle }
                .id(convo.id)
        } else {
            EmptyState(systemImage: "envelope.open", title: "No thread selected",
                       message: "Pick a conversation to read it here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(p.bgBase.ignoresSafeArea())
                // In the detail column's (empty) bar, where it sits when a thread is open.
                .toolbar { loreToggle }
        }
    }

    /// On the folder pane (landscape): hide the folders, leaving list + reader. The
    /// list header then shows the button that brings them back.
    @ViewBuilder private var hideFoldersButton: some View {
        if wide && selection == 0 {
            Button { withAnimation { foldersHidden = true } } label: {
                Image(systemName: "sidebar.left")
                    .font(AppFont.glyph(17, .regular))
                    .foregroundStyle(p.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .accessibilityLabel("Hide folders")
        }
    }

    /// Opens Lore; once open, the panel's own corner button closes it.
    @ToolbarContentBuilder private var loreToggle: some ToolbarContent {
        if !showLore {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation { loreBinding.wrappedValue = true } } label: {
                    Image(systemName: "sidebar.right").foregroundStyle(p.textSecondary)
                }
                .accessibilityLabel("Show Lore")
            }
        }
    }

    /// Icon rail + panel (Outlook/Teams-style): a thin rail of section icons — Mail,
    /// Lore, Calendar, and Settings (a sheet) at its foot — beside the active section's
    /// panel: Mail's folders, or Calendar's new event / mini month / coming up. Lore
    /// has no panel, so the column shrinks to the rail. In portrait a folder pick
    /// slides the message list over the panel — a plain swap, not a NavigationStack
    /// push: a stack in a split column pushes over the whole column, rail included.
    private var sidebar: some View {
        HStack(spacing: 0) {
            rail
            if selection == 0 && wide {
                if !foldersHidden { panel.frame(width: Self.folderWidth) }
                inboxList(onBack: nil, onShowFolders: foldersHidden ? { withAnimation { foldersHidden = false } } : nil,
                          underStatusBar: !foldersHidden)
            } else if selection != 1 {
                ZStack {
                    if sidebarPath.last == Self.listPage {
                        inboxList(onBack: { sidebarPath.removeAll() })
                            .transition(.move(edge: .trailing))
                    } else {
                        panel.transition(.move(edge: .leading))
                    }
                }
                .clipped()
                .animation(.easeInOut(duration: 0.25), value: sidebarPath)
            }
        }
        .toolbar(removing: .sidebarToggle)
        // In the Inbox this column also carries the message list, so it gets list width.
        .navigationSplitViewColumnWidth(min: columnWidth.min, ideal: columnWidth.ideal, max: columnWidth.max)
    }

    private static let railWidth: CGFloat = 56
    private static let folderWidth: CGFloat = 240
    private var columnWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        let r = Self.railWidth
        if selection == 1 { return (r, r, r) }
        if selection == 0 {
            let f = wide && !foldersHidden ? Self.folderWidth : 0
            return (r + f + 320, r + f + 380, r + f + 460)
        }
        return (r + 200, r + 240, r + 280)
    }

    private var rail: some View {
        VStack(spacing: Space.s1) {
            ForEach(0..<3, id: \.self) { i in railButton(i) }
            Spacer()
            railButton(3)
        }
        .padding(.top, Space.s2).padding(.bottom, Space.s3)
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity)
        .background {
            if p.isDark {
                LinearGradient(colors: [p.bgPanel, p.bgBase], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            } else {
                p.bgSurface.ignoresSafeArea() // one quiet tone: the change of colour is the edge
            }
        }
        .overlay(alignment: .trailing) {
            if p.isDark {
                HStack(spacing: 0) { Color.bevel(0.03).frame(width: 1); edgeLine.frame(width: 1) }
                    .ignoresSafeArea()
            }
        }
    }

    /// A rail icon. The active section is a pill in its own bright tab colour where
    /// the theme has rainbow tabs (Groovebox: Mail coral, Lore amber, Calendar
    /// violet — the phone tab bar's colours), else the dark selection pill.
    private func railButton(_ i: Int) -> some View {
        let active = i == selection && i != 3
        // The phone bar's slots: Inbox 0, Lore 1, (Compose 2), Calendar 3, Settings 4.
        let tint = p.navTabColors.flatMap { c in c.isEmpty ? nil : c[[0, 1, 3, 4][i] % c.count] }
        return Button { withAnimation(.easeOut(duration: 0.2)) { go(i) } } label: {
            Image(systemName: sections[i].icon)
                .font(AppFont.glyph(19, active ? .semibold : .regular))
                .foregroundStyle(active ? (tint != nil ? p.solidChipInk ?? .black : p.textPrimary) : p.textSecondary)
                .frame(width: 42, height: 42)
                .background {
                    if active, let tint {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint)
                    } else if active {
                        selectionPill(radius: 12)
                    }
                }
                .frame(width: Self.railWidth, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(sections[i].label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The selected-item surface: the same colour as the open thread in the list.
    private func selectionPill(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(p.selectedRowFill ?? p.accentViolet.opacity(0.12))
            .overlay {
                if let outline = p.selectionOutline {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(outline, lineWidth: 1.5)
                }
            }
    }

    /// Light themes get the list's soft line; the dark groove belongs to dark themes.
    private var edgeLine: Color { p.isDark ? .scrim(0.45) : p.borderSubtle }

    @ViewBuilder private var panel: some View {
        if selection == 2 {
            sidebarPage("Calendar") {
                sidebarAction("New event", icon: "calendar.badge.plus") { chrome.calendarCreateTick += 1 }
                    .disabled(!chrome.calendarCanCreate)
                    .opacity(chrome.calendarCanCreate ? 1 : 0.4)
                navGroup("Month", icon: "calendar") { SidebarMiniMonth() }
                navGroup("Coming up", icon: "clock") { SidebarComingUp() }
            }
        } else {
            sidebarPage("Mail") {
                if let meta = activeProvider.flatMap({ MailFolder.meta(for: $0) }) {
                    navGroup(split.channelLabel, icon: "tray.fill") { ForEach(meta) { folderItem($0) } }
                } else {
                    navGroup(split.channelLabel, icon: "tray.fill") {
                        ForEach(MailFolder.mailboxes) { folder in
                            // An MX domain chip: its Inbox row becomes the address-folder tree.
                            if folder == .inbox && !addressFolders.folders.isEmpty {
                                AddressFolderTree(selection: $selectedFolder, dense: true) { if !wide { sidebarPath = inboxPath } }
                            } else {
                                folderItem(folder)
                            }
                        }
                    }
                    navGroup("Triage", icon: "square.grid.2x2.fill") { ForEach(MailFolder.triage) { folderItem($0) } }
                }
            }
        }
    }

    private func sidebarAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(AppFont.sm(.semibold))
                .foregroundStyle(p.accentViolet)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4).padding(.vertical, Space.s3)
        }
        .buttonStyle(.plain)
    }

    /// A sidebar page with its own header row instead of the navigation bar: the
    /// system bar re-animated its glass buttons on every shell update (flicker).
    private func sidebarPage(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s2) {
                Text(title).font(AppFont.lg(.semibold)).foregroundStyle(p.textPrimary)
                    .padding(.leading, Space.s2)
                Spacer()
                hideFoldersButton
            }
            .frame(height: 44)
            .padding(.horizontal, Space.s3)
            ScrollView {
                VStack(spacing: 0) { content() }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(p.bgPanel.ignoresSafeArea())
        // Desktop's sidebar edge: a dark groove with a faint highlight inside it.
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) { Color.bevel(0.03).frame(width: 1); edgeLine.frame(width: 1) }
                .ignoresSafeArea()
        }
    }

    /// Desktop `NavGroup`: an uppercase metallic header bar over its rows.
    private func navGroup(_ title: String, icon: String, @ViewBuilder _ rows: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s2) {
                Image(systemName: icon).font(AppFont.glyph(11, .semibold)).opacity(0.6)
                Text(title.uppercased()).font(AppFont.glyph(11, .bold)).tracking(1.3).lineLimit(1)
                Spacer()
            }
            .foregroundStyle(p.textTertiary)
            .padding(.vertical, Space.s2).padding(.leading, Space.s4).padding(.trailing, Space.s3)
            .background(LinearGradient(colors: [.bevel(0.06), .bevel(0.02), .scrim(0.04), .scrim(0.08)],
                                       startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) { Color.bevel(0.04).frame(height: 1) }
            .overlay(alignment: .bottom) { edgeLine.frame(height: 1) }
            VStack(spacing: 0) { rows() }.padding(.vertical, Space.s2)
        }
        .overlay(alignment: .bottom) { edgeLine.frame(height: 1) }
    }

    private func folderItem(_ folder: MailFolder) -> some View {
        navItem(folder.title, icon: folder.icon, active: folder == selectedFolder && addressFolders.openFolder == nil,
                tint: folder.tintHex.map { Color(hex: $0) }) {
            selectedFolder = folder
            addressFolders.selected = nil
            if !wide { sidebarPath = inboxPath }
        }
    }

    /// Desktop `NavItem`: dense row, faint icon; active = warm accent text + fading
    /// wash + a 3pt gradient rail on the leading edge.
    /// Desktop `NavItem` density, no rail line. The active row is the theme's select
    /// keycap where it has one (Groovebox: the cream key, dark ink), else the dark
    /// selection pill with light ink; triage tints stay on their icons.
    private func navItem(_ title: String, icon: String, active: Bool, tint: Color? = nil,
                         chevron: Bool = false, action: @escaping () -> Void) -> some View {
        let ink = active ? p.keycapLabel(.selected, or: p.textPrimary) : p.textSecondary
        return Button(action: action) {
            HStack(spacing: Space.s2 + 2) {
                Image(systemName: icon)
                    .font(AppFont.glyph(15, .semibold))
                    .foregroundStyle(tint ?? ink)
                    .opacity(tint != nil ? (active ? 1 : 0.7) : (active ? 1 : 0.4))
                    .frame(width: 20)
                Text(title)
                    .font(AppFont.sm(active ? .bold : .medium))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if chevron {
                    Image(systemName: "chevron.right").font(AppFont.glyph(11, .semibold)).foregroundStyle(p.textMuted)
                }
            }
            .padding(.vertical, Space.s2 + 1).padding(.horizontal, Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if active, let key = p.selectKeycap { Color.clear.keycap(key, radius: 10) }
                else if active { selectionPill(radius: 10) }
            }
            .padding(.horizontal, Space.s2).padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
