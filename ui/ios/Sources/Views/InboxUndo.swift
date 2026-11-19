import SwiftUI

/// A removed batch of conversations (one for a swipe, N for a bulk action) plus the
/// action applied and its reverse, so the undo toast can re-insert the rows in place
/// and fire the reversing write-back.
struct UndoBanner: Equatable {
    /// One removed row + its original position, so undo can re-insert it in place.
    /// `reverse`: when this row's undo differs from the banner's (Lore's per-member tick).
    struct Item: Equatable { let convo: Conversation; let index: Int; var reverse: ConversationAction? = nil }
    let items: [Item]                       // 1 for a swipe, N for a bulk action
    let action: ConversationAction          // the action applied
    let reverse: ConversationAction?        // the action that undoes it

    var primary: Conversation? { items.first?.convo }
    var count: Int { items.count }
}

/// Owns the inbox's undo toast: the active banner, the swipe-drag offset, the 5-second
/// auto-dismiss, and the reversing write-back. Split out of `InboxListView`; the list
/// still owns its `conversations` / `pendingRemoved`, so `undo` takes a `reinsert`
/// closure to put the removed rows back. Same observation pattern as `EngineModel`
/// (`@MainActor` + `ObservableObject` + `@Published`).
@MainActor
final class InboxUndoController: ObservableObject {
    @Published var banner: UndoBanner?
    /// Live upward drag on the top toast (swipe-up-to-dismiss); resets on release.
    @Published var toastDrag: CGFloat = 0

    /// Show an undo toast for `entry`, then auto-dismiss it after 5s.
    func show(_ entry: UndoBanner) {
        withAnimation { banner = entry }
        scheduleDismiss(entry)
    }

    /// Auto-dismiss a toast 5s after it appears, unless it was already replaced/undone.
    func scheduleDismiss(_ entry: UndoBanner) {
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if banner == entry { withAnimation { banner = nil } }
        }
    }

    /// Reverse the banner's action: re-insert removed rows in original order (via
    /// `reinsert`, which restores the list's own state) and fire the reverse
    /// write-back once per account (the FFI is account-scoped).
    func undo(engine: EngineModel, cloud: CloudSession, reinsert: (UndoBanner.Item) -> Void) {
        guard let banner, let reverse = banner.reverse else { return }
        withAnimation {
            // Re-insert in original order so earlier rows land before later ones.
            for item in banner.items.sorted(by: { $0.index < $1.index }) {
                reinsert(item)
            }
            self.banner = nil
        }
        let byTarget = Dictionary(grouping: banner.items) { "\($0.convo.accountKey)|\(($0.reverse ?? reverse).verb)" }
        for items in byTarget.values {
            let action = items[0].reverse ?? reverse
            Task { await engine.perform(accountKey: items[0].convo.accountKey, conversationKeys: items.map(\.convo.id), action: action, cloud: cloud) }
        }
    }
}

/// Shared toast chrome: a circular action-icon badge (neutral recessed surface) —
/// or a channel avatar — plus title/subtitle and a trailing control, wrapped in the
/// floating `glowCapsule`. Used by the inbox undo toast + the "Message sent" toast.
struct ToastRow<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let subtitle: String?
    let tint: Color?
    let avatar: Channel?
    let colors: [Color]
    let trailing: Trailing
    private var p: ThemePalette { theme.palette }

    init(icon: String, title: String, subtitle: String? = nil, tint: Color? = nil,
         avatar: Channel? = nil, colors: [Color] = GlowCapsule.inboxAccent,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.avatar = avatar
        self.colors = colors
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Space.s3) {
            if let avatar {
                ChannelBadge(channel: avatar, size: 32)
            } else {
                Image(systemName: icon)
                    .font(AppFont.base(.semibold))
                    .foregroundStyle(tint ?? p.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(p.bgBase))
                    .overlay(Circle().stroke(p.borderStrong, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(AppFont.sm).foregroundStyle(p.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppFont.xs)
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Space.s2)
            trailing
        }
        .padding(.leading, Space.s2)
        .padding(.trailing, Space.s3)
        .padding(.vertical, Space.s2)
        .frame(maxWidth: .infinity)
        .glowCapsule(colors: colors)
        .padding(.horizontal, Space.s3)
    }
}
