import SwiftUI

/// The iPad command palette, after desktop's `CommandPalette`
/// (`ui/web/src/components/CommandPalette/`): ⌘K or the rail button opens it.
/// Type to filter screens, folders, accounts and actions; the same text finds
/// conversations and people. ↑↓ move, Return runs, Esc closes. The four most
/// recent commands sit on top.
struct PaletteCommand: Identifiable {
    enum Group: String, CaseIterable { case recent = "Recent", go = "Go to", accounts = "Accounts", actions = "Actions", mail = "In connected mailboxes", people = "People" }
    let id: String
    let group: Group
    let title: String
    var subtitle: String? = nil
    let icon: String
    var keywords: String = ""
    var shortcut: String? = nil
    let run: () -> Void
}

@MainActor final class PaletteRecents {
    private static let key = "palette.recent"
    static let limit = 4
    static func read() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func push(_ id: String) {
        UserDefaults.standard.set(Array(([id] + read().filter { $0 != id }).prefix(limit)), forKey: key)
    }
}

struct CommandPaletteView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    let commands: [PaletteCommand]
    let onClose: () -> Void
    /// "Search mail for …" when nothing else matches.
    let searchMail: (String) -> Void
    let openConversation: (Conversation) -> Void

    @State private var query = ""
    @State private var cursor = 0
    @State private var found: [Conversation] = []
    @State private var people: [Contact] = []
    @FocusState private var focused: Bool
    private var p: ThemePalette { theme.palette }

    private var rows: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let recent = PaletteRecents.read()
            let byId = Dictionary(commands.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let top = recent.compactMap { id in byId[id].map { PaletteCommand(id: $0.id, group: .recent, title: $0.title, subtitle: $0.subtitle, icon: $0.icon, shortcut: $0.shortcut, run: $0.run) } }
            return top + commands.filter { !recent.contains($0.id) }
        }
        let hits = commands.compactMap { c -> (PaletteCommand, Int)? in
            if let s = PaletteMatch.score(q, c.title) { return (c, s) }
            if !c.keywords.isEmpty, let s = PaletteMatch.score(q, c.keywords) { return (c, s - 20) }
            return nil
        }
        .sorted { $0.1 > $1.1 }.prefix(12).map(\.0)
        let mail = found.prefix(6).map { c in
            PaletteCommand(id: "conv:\(c.id)", group: .mail, title: c.subject.isEmpty ? "(no subject)" : c.subject,
                           subtitle: { let f = MailAddress.parse(c.fromAddress); return f.name.isEmpty ? f.email : f.name }(),
                           icon: "envelope") { openConversation(c) }
        }
        let who = people.prefix(4).map { c in
            PaletteCommand(id: "person:\(c.email)", group: .people, title: c.name.isEmpty ? c.email : c.name,
                           subtitle: "Show mail with \(c.email)", icon: "person.crop.circle") { searchMail(c.email) }
        }
        let fallback = PaletteCommand(id: "search", group: .actions, title: "Search mail for “\(q)”", icon: "magnifyingglass") { searchMail(q) }
        return Array(hits) + mail + who + [fallback]
    }

    var body: some View {
        let list = rows
        ZStack(alignment: .top) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                HStack(spacing: Space.s3) {
                    Image(systemName: "magnifyingglass").font(AppFont.md).foregroundStyle(p.textTertiary)
                    TextField("Type a command or search", text: $query)
                        .font(AppFont.lg).foregroundStyle(p.textPrimary)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit { run(list, cursor) }
                    Text("esc").font(AppFont.xs3(.semibold)).foregroundStyle(p.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(p.borderSubtle))
                }
                .padding(Space.s4)
                Divider().overlay(p.borderSubtle)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, cmd in
                                if i == 0 || list[i - 1].group != cmd.group {
                                    Text(cmd.group.rawValue.uppercased()).font(AppFont.xs3(.semibold)).tracking(0.8)
                                        .foregroundStyle(p.textTertiary)
                                        .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s1)
                                }
                                Button { run(list, i) } label: { row(cmd, active: i == cursor) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(cmd.subtitle.map { "\(cmd.title), \($0)" } ?? cmd.title)
                                    .accessibilityAddTraits(i == cursor ? .isSelected : [])
                                    .id(i)
                            }
                        }
                        .padding(.bottom, Space.s2)
                    }
                    .onChange(of: cursor) { _, c in withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(c) } }
                }
                .frame(maxHeight: 420)
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(p.bgPanel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.borderSubtle))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .frame(maxWidth: 620)
            .padding(.top, 90).padding(.horizontal, Space.s5)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in cursor = 0 }
        .task(id: query) { await find(query) }
        .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(list.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .background {
            Button("", action: onClose).keyboardShortcut(.escape, modifiers: []).hidden()
        }
    }

    private func row(_ cmd: PaletteCommand, active: Bool) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: cmd.icon).font(AppFont.sm).foregroundStyle(active ? p.accentViolet : p.textSecondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(cmd.title).font(AppFont.sm(.medium)).foregroundStyle(p.textPrimary).lineLimit(1)
                if let s = cmd.subtitle { Text(s).font(AppFont.xs3).foregroundStyle(p.textTertiary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let k = cmd.shortcut { Text(k).font(AppFont.xs3(.semibold)).monospaced().foregroundStyle(p.textTertiary) }
        }
        .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
        .background { if active { RoundedRectangle(cornerRadius: 8).fill(p.accentViolet.opacity(0.14)).padding(.horizontal, Space.s2) } }
        .contentShape(Rectangle())
    }

    private func run(_ list: [PaletteCommand], _ i: Int) {
        guard list.indices.contains(i) else { return }
        let cmd = list[i]
        if !cmd.id.hasPrefix("conv:") && !cmd.id.hasPrefix("person:") && cmd.id != "search" { PaletteRecents.push(cmd.id) }
        onClose()
        cmd.run()
    }

    /// Conversations and people, as the query settles. Connected mailboxes only
    /// (the engine's full-text index): inbox2-hosted mail is in the MX mirror,
    /// which "Search mail for …" reaches through the list's own search.
    private func find(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { found = []; people = []; return }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let (convs, contacts) = await engine.store.read { store in
            (store.conversations(accountKey: nil, folder: .inbox, filter: .all, query: q),
             store.contacts().filter { $0.email.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) })
        }
        guard !Task.isCancelled else { return }
        found = Array(convs.prefix(6)); people = Array(contacts.prefix(4))
    }
}
