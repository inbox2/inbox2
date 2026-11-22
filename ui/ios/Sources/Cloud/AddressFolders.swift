import SwiftUI

// Address folders: the store and tree. The `AddressFolder` DTO is in CloudDTOs.swift.

/// How the MX list narrows by address folder (local mirror + REST).
enum MxFolderFilter: Sendable {
    /// One folder: the row's `folder` equals this key.
    case address(String)
    /// Inbox: rows in a folder shown in Inbox (per domain key), or `direct` ones.
    /// Domains without a loaded tree are not filtered.
    case inbox([String: [String]])
}

/// The folder trees (per `dom_…` key), which domain chip the inbox shows and the
/// open folder. One per process; the drawer, the iPad sidebar and the list share it.
@MainActor
final class AddressFolderStore: ObservableObject {
    static let shared = AddressFolderStore()

    struct Scope: Equatable { let orgId: String; let domain: String }

    @Published private(set) var trees: [String: [AddressFolder]] = [:]
    /// The MX domain chip on screen; nil on unified or a channel chip.
    @Published private(set) var scope: Scope?
    /// The open address folder's key (Inbox of the drawer's mailboxes when nil).
    @Published var selected: String?
    /// Bumped when a tree changes, so the list re-filters (its reload key).
    @Published private(set) var version = 0
    private var inFlight: Set<String> = []

    var folders: [AddressFolder] { scope.flatMap { trees[$0.domain] } ?? [] }
    var openFolder: AddressFolder? { selected.flatMap { k in folders.first { $0.key == k } } }

    /// The From default while a folder you can reply as is open.
    var replyAs: (orgId: String, address: String)? {
        guard let scope, let f = openFolder, f.canReply, let a = f.address else { return nil }
        return (scope.orgId, a)
    }

    /// The Inbox's folder keys per loaded domain, for the local list filter.
    var inboxFilter: MxFolderFilter {
        .inbox(trees.mapValues { $0.filter { $0.kind != .inbox && $0.inInbox }.map(\.key) })
    }

    private var lastDomain: Scope?

    /// The inbox switched chip: another domain starts back on its Inbox. Passing
    /// through unified keeps the pick (iPad portrait remounts the list as unified first).
    func show(_ s: Scope?) {
        if let s, s != lastDomain { lastDomain = s; selected = nil }
        if s != scope { scope = s }
        if let s { Task { await load(s) } }
    }

    func reset() { trees = [:]; scope = nil; lastDomain = nil; selected = nil }

    /// The domain on screen (pull-to-refresh, a mutation).
    func reloadActive() { if let scope { Task { await load(scope) } } }

    /// Every domain of every org, so the unified Inbox can filter them all (new mail, foreground).
    func refreshAll() {
        for org in CloudSession.shared.orgs {
            for d in org.domains ?? [] { Task { await load(.init(orgId: org.id, domain: d.id)) } }
        }
    }

    func load(_ s: Scope) async {
        guard inFlight.insert(s.domain).inserted else { return }
        defer { inFlight.remove(s.domain) }
        guard let tree = await CloudSession.shared.addressFolders(orgId: s.orgId, domain: s.domain),
              trees[s.domain] != tree else { return }
        trees[s.domain] = tree
        version += 1
    }

    /// Bell / Show in Inbox: optimistic, then saved and the tree refetched (Show in
    /// Inbox changes what Inbox counts).
    func setPref(_ f: AddressFolder, inbox: Bool? = nil, notify: Bool? = nil) {
        guard let scope, var tree = trees[scope.domain], let i = tree.firstIndex(of: f) else { return }
        if let inbox { tree[i].inInbox = inbox }
        if let notify { tree[i].notify = notify }
        trees[scope.domain] = tree
        version += 1
        Task {
            await CloudSession.shared.setAddressFolderPref(orgId: scope.orgId, address: f.prefKey, inbox: inbox, notify: notify)
            await load(scope)
        }
    }
}

// MARK: - Tree

/// The MX domain's Inbox with its address folders under it: Yours (your address,
/// each +tag indented), Shared and Other. Yours and Shared collapse and show their
/// total unread. A row's bell flips notifications; long-press for Show in Inbox.
/// Renders nothing outside an MX domain chip, so hosts show their own Inbox row then.
struct AddressFolderTree: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = AddressFolderStore.shared
    @Binding var selection: MailFolder
    /// iPad sidebar density (smaller type and padding than the phone drawer).
    var dense = false
    var onPick: () -> Void = {}
    @AppStorage("addressTree.yoursOpen") private var yoursOpen = false
    @AppStorage("addressTree.sharedOpen") private var sharedOpen = false

    private var p: ThemePalette { theme.palette }
    private var hPad: CGFloat { dense ? Space.s3 : Space.s5 }

    var body: some View {
        let all = store.folders
        if let inbox = all.first(where: { $0.kind == .inbox }) {
            let yours = all.filter { $0.kind == .own }.flatMap { o in [o] + all.filter { $0.kind == .tag && $0.parent == o.key } }
            let shared = all.filter { $0.kind == .shared }
            VStack(spacing: 0) {
                row(inbox, active: selection == .inbox && store.openFolder == nil) { store.selected = nil }
                group("Yours", yours, open: $yoursOpen)
                group("Shared", shared, open: $sharedOpen)
                if let other = all.first(where: { $0.kind == .other }) { folderRow(other) }
            }
        }
    }

    /// A collapsed group still shows the open folder, so the selection never hides.
    @ViewBuilder private func group(_ title: String, _ list: [AddressFolder], open: Binding<Bool>) -> some View {
        if !list.isEmpty {
            let unread = list.reduce(0) { $0 + $1.unread }
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.wrappedValue.toggle() } } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(AppFont.glyph(10, .semibold))
                        .frame(width: dense ? 20 : 28)
                    Text(title.uppercased()).font(AppFont.xs2(.semibold)).tracking(0.8)
                    Spacer()
                    if unread > 0 { count(unread) }
                }
                .foregroundStyle(p.textTertiary)
                .padding(.leading, hPad + Space.s4).padding(.trailing, hPad)
                .padding(.vertical, dense ? Space.s1 + 2 : Space.s2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(open.wrappedValue ? "Collapse" : "Expand") \(title)")
            ForEach(open.wrappedValue ? list : list.filter { $0.key == store.selected }) { folderRow($0) }
        }
    }

    private func folderRow(_ f: AddressFolder) -> some View {
        row(f, active: selection == .inbox && store.selected == f.key) { store.selected = f.key }
    }

    private func row(_ f: AddressFolder, active: Bool, select: @escaping () -> Void) -> some View {
        let indent: CGFloat = f.kind == .inbox ? 0 : (f.kind == .tag ? Space.s4 * 2 : Space.s4)
        return HStack(spacing: Space.s2) {
            Button {
                select()
                selection = .inbox
                onPick()
            } label: {
                HStack(spacing: dense ? Space.s2 + 2 : Space.s3) {
                    Image(systemName: f.icon)
                        .font(dense ? AppFont.glyph(15, .semibold) : AppFont.lg(.medium))
                        .foregroundStyle(active ? p.accentViolet : p.textSecondary)
                        .frame(width: dense ? 20 : 28)
                    Text(f.treeLabel)
                        .font(dense ? AppFont.sm(active ? .bold : .medium) : AppFont.body(active ? .semibold : .regular))
                        .foregroundStyle(active ? p.textPrimary : p.textSecondary)
                        .lineLimit(1)
                    replyMark(f)
                    Spacer(minLength: 0)
                    if f.unread > 0 { count(f.unread) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if f.hasPrefs {
                Button { store.setPref(f, notify: !f.notify) } label: {
                    Image(systemName: f.notify ? "bell.fill" : "bell.slash")
                        .font(AppFont.glyph(12, .medium))
                        .foregroundStyle(f.notify ? p.accentViolet : p.textMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(f.notify ? "Notifications on" : "Notifications off")
            }
        }
        .padding(.leading, hPad + indent).padding(.trailing, hPad - Space.s1)
        .padding(.vertical, dense ? Space.s1 : Space.s2)
        .background(active ? p.accentViolet.opacity(0.12) : .clear)
        .contextMenu {
            if f.hasInboxToggle {
                Button { store.setPref(f, inbox: !f.inInbox) } label: { check("Show in Inbox", f.inInbox) }
            }
            if f.hasPrefs {
                Button { store.setPref(f, notify: !f.notify) } label: { check("Notify me", f.notify) }
            }
        }
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Menu rows: a check when on.
    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Green pen (you can reply as it) or amber eye (read only), for address rows.
    @ViewBuilder private func replyMark(_ f: AddressFolder) -> some View {
        if f.kind == .own || f.kind == .shared {
            Image(systemName: f.canReply ? "pencil" : "eye")
                .font(AppFont.glyph(11, .semibold))
                .foregroundStyle(f.canReply ? p.accentSuccess : p.accentAmber)
                .accessibilityLabel(f.canReply ? "You can reply as this address" : "Read only")
        }
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)").font(AppFont.xs(.semibold)).foregroundStyle(p.textTertiary).monospacedDigit()
    }
}

/// Top of a shared folder's list when you can read the address but not send as it.
/// Reply-as is an admin setting; there is no request flow (decided 2026-11).
struct ReadOnlyFolderNotice: View {
    @Environment(\.theme) private var theme
    let folder: AddressFolder

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "eye").font(AppFont.glyph(12, .semibold)).foregroundStyle(theme.palette.accentAmber)
            Text("You can read \(folder.label) but not reply as it. An admin gives reply-as in the console.")
                .font(AppFont.sm).foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
