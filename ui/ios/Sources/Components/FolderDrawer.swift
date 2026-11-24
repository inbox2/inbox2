import SwiftUI

/// Fullscreen slide-in folder/mailbox drawer (replaces the half-sheet picker). A
/// translucent material panel slides in from the left over everything (including
/// the floating nav); tap the dimmed area or the close button to dismiss.
struct FolderDrawer: View {
    @Environment(\.theme) private var theme
    @Binding var isPresented: Bool
    @Binding var selection: MailFolder
    var channelLabel: String = ""
    /// The active account's provider type. Meta accounts (Instagram/Messenger/
    /// WhatsApp) show channel/kind sub-views instead of mailboxes + triage.
    var provider: String? = nil
    @State private var shown = false
    /// An MX domain chip's address folders: its Inbox row becomes the folder tree.
    @ObservedObject private var addressFolders = AddressFolderStore.shared
    @EnvironmentObject private var chrome: ChromeModel

    private var metaFolders: [MailFolder]? { provider.flatMap { MailFolder.meta(for: $0) } }

    private var p: ThemePalette { theme.palette }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.scrim(shown ? 0.35 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mailboxes")
                                .font(AppFont.display)
                                .foregroundStyle(p.textPrimary)
                            Text(channelLabel)
                                .font(AppFont.sm)
                                .foregroundStyle(p.textTertiary)
                        }
                        Spacer()
                        Button { close() } label: {
                            Image(systemName: "xmark")
                                .font(AppFont.base(.semibold))
                                .foregroundStyle(p.textSecondary)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(p.bgElevated.opacity(0.7)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Space.s5)
                    // The panel ignoresSafeArea so its material fills the screen;
                    // add the status-bar inset back so the title clears the clock
                    // (a flat top pad crowds the status bar on notched devices).
                    .padding(.top, geo.safeAreaInsets.top + Space.s4)
                    .padding(.bottom, Space.s5)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let metaFolders {
                                // Meta account: channel/kind sub-views (no mail folders / triage).
                                ForEach(metaFolders) { folderRow($0) }
                            } else {
                                ForEach(MailFolder.mailboxes) { folder in
                                    if folder == .inbox && !addressFolders.folders.isEmpty {
                                        AddressFolderTree(selection: $selection, onPick: close)
                                    } else {
                                        folderRow(folder)
                                        if folder == .inbox { unifiedFolders }
                                    }
                                }

                                Text("TRIAGE")
                                    .font(AppFont.xs2(.semibold)).tracking(0.8)
                                    .foregroundStyle(p.textTertiary)
                                    .padding(.horizontal, Space.s5)
                                    .padding(.top, Space.s5).padding(.bottom, Space.s2)
                                ForEach(MailFolder.triage) { folderRow($0) }
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, alignment: .topLeading)
                .background(.ultraThinMaterial)
                .background(p.bgBase.opacity(0.5))
                .ignoresSafeArea()
                .offset(x: shown ? 0 : -geo.size.width)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { shown = true } }
    }

    private func folderRow(_ folder: MailFolder) -> some View {
        // Inbox with a folder open is not this row's Inbox.
        let active = folder == selection && addressFolders.openFolder == nil
        // Triage folders carry their own desktop quadrant tint (always coloured, like
        // the desktop matrix); standard mailboxes use the violet active treatment.
        let tint = folder.tintHex.map { Color(hex: $0) }
        let accent = tint ?? p.accentViolet
        return Button {
            selection = folder
            addressFolders.selected = nil
            close()
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: folder.icon)
                    .font(AppFont.lg(.medium))
                    .foregroundStyle(tint ?? (active ? p.accentViolet : p.textSecondary))
                    .frame(width: 28)
                Text(folder.title)
                    .font(AppFont.body(active ? .semibold : .regular))
                    .foregroundStyle(active ? p.textPrimary : p.textSecondary)
                Spacer()
                if active { Circle().fill(accent).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s3 + 2)
            .background(active ? accent.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Unified Inbox: each MX domain's folders not already in Inbox, like the iPad
    /// sidebar (a domain with none is left out). Domains start collapsed; a plus
    /// address sits under its parent when that is listed, else shows in full. A tap
    /// on a folder opens that domain's tab with the folder selected.
    @ViewBuilder private var unifiedFolders: some View {
        if provider == nil, addressFolders.scope == nil, let org = CloudSession.shared.currentOrg {
            ForEach(org.domains ?? [], id: \.id) { d in
                let list = (addressFolders.trees[d.id] ?? []).filter { ($0.kind == .own || $0.kind == .shared || $0.kind == .tag) && !$0.inInbox }
                if !list.isEmpty { domainSection(d.id, d.name, list) }
            }
        }
    }

    @AppStorage("drawer.unifiedDomainsOpen") private var openDomainIds = ""

    @ViewBuilder private func domainSection(_ id: String, _ name: String, _ list: [AddressFolder]) -> some View {
        let open = openDomainIds.split(separator: ",").contains(Substring(id))
        Button {
            var ids = openDomainIds.split(separator: ",").map(String.init).filter { $0 != id }
            if !open { ids.append(id) }
            withAnimation(.easeInOut(duration: 0.15)) { openDomainIds = ids.joined(separator: ",") }
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(AppFont.glyph(11, .semibold)).foregroundStyle(p.textTertiary).frame(width: 28)
                Text(name).font(AppFont.body(.regular)).foregroundStyle(p.textSecondary).lineLimit(1)
                Spacer()
                let unread = list.reduce(0) { $0 + $1.unread }
                if unread > 0 { Text("\(unread)").font(AppFont.xs(.semibold)).monospacedDigit().foregroundStyle(p.textTertiary) }
            }
            .padding(.leading, Space.s5 + Space.s4).padding(.trailing, Space.s5)
            .padding(.vertical, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(open ? "Collapse" : "Expand") \(name)")
        if open {
            let listed = Set(list.map(\.key))
            ForEach(list.filter { $0.kind != .tag || !listed.contains($0.parent ?? "") }) { f in
                unifiedRow(f, domain: id, depth: 1, label: f.key)
                if f.kind != .tag {
                    ForEach(list.filter { $0.kind == .tag && $0.parent == f.key }) { unifiedRow($0, domain: id, depth: 2, label: $0.treeLabel) }
                }
            }
        }
    }

    private func unifiedRow(_ f: AddressFolder, domain: String, depth: Int, label: String) -> some View {
        let icon = f.kind == .shared ? "tray" : f.kind == .tag ? "tag" : "person"
        let indent = Space.s4 * CGFloat(depth + 1)
        return Button {
            addressFolders.pendingSelect = (domain: domain, key: f.key)
            chrome.pendingChannel = domain
            chrome.focusChannel = domain
            selection = .inbox
            close()
        } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: icon)
                    .font(AppFont.base(.medium)).foregroundStyle(p.textSecondary).frame(width: 28)
                Text(label).font(AppFont.body(.regular)).foregroundStyle(p.textSecondary).lineLimit(1)
                Spacer()
                if f.unread > 0 {
                    Text("\(f.unread)").font(AppFont.xs(.semibold)).monospacedDigit().foregroundStyle(p.textTertiary)
                }
            }
            .padding(.leading, Space.s5 + indent).padding(.trailing, Space.s5)
            .padding(.vertical, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func close() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { isPresented = false }
    }
}
