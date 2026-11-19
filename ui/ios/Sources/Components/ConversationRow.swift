import SwiftUI

/// A conversation list row — avatar, sender, time, subject, snippet, unread dot,
/// and an optional status tag. Mirrors the desktop ConversationItem.
///
/// Long-press is split by region: holding the avatar fires `onAvatarLongPress`
/// (the inbox enters multi-select), while holding the text column opens the
/// `contentMenu` action menu (no Select item). The menu is a `Menu` with
/// `primaryAction` — NOT `.contextMenu`, which a List promotes to the whole
/// cell, so it would also fire on the avatar and race the multi-select gesture.
///
/// The row is deliberately NOT wrapped in a Button/NavigationLink; the text column
/// opens via the Menu's `primaryAction` and the avatar via its own `onTapGesture`,
/// both calling `onOpen`. The Menu's label is the text column itself — a clear
/// stand-in label (what this used to be, to stop the text vanishing while the menu
/// is open) left the drag tracking against an empty button and made the menu
/// flicker. The text is kept on screen by a copy behind the label instead.
struct ConversationRow<ContentMenu: View>: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var held = HeldModifiers.shared
    let convo: Conversation
    /// The conversation's channel, shown as a corner badge on the avatar. Set
    /// only in the unified inbox (nil in single-channel views, where the
    /// channel is implied by the active tab).
    private let channelBadge: Channel?
    /// Sent folder: name + avatar the recipient instead of the (self) sender.
    private let isSent: Bool
    private let onAvatarLongPress: (() -> Void)?
    private let onOpen: (() -> Void)?
    private let contentMenu: () -> ContentMenu

    init(convo: Conversation,
         channelBadge: Channel? = nil,
         isSent: Bool = false,
         onAvatarLongPress: (() -> Void)? = nil,
         onOpen: (() -> Void)? = nil,
         @ViewBuilder contentMenu: @escaping () -> ContentMenu) {
        self.convo = convo
        self.channelBadge = channelBadge
        self.isSent = isSent
        self.onAvatarLongPress = onAvatarLongPress
        self.onOpen = onOpen
        self.contentMenu = contentMenu
    }

    private var p: ThemePalette { theme.palette }
    private var hasMenu: Bool { ContentMenu.self != EmptyView.self }

    // The row's primary identity — recipient in Sent, sender everywhere else.
    private var displayName: String { isSent ? convo.recipient : convo.sender }
    private var avatarInitials: String { isSent ? convo.recipientInitials : convo.initials }
    private var avatarSeed: Int { isSent ? convo.recipientSeed : convo.seed }
    private var avatarEmail: String { isSent ? (MailAddress.parseList(convo.toAddress).first?.email ?? "") : convo.email }
    private var displayTime: String { isSent ? convo.sentTime : convo.time }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            avatar

            if hasMenu, held.selecting {
                // Shift or Command is down: a modified click on a Menu never fires its
                // primaryAction, so the text column is a plain tap target meanwhile.
                textColumn.opacity(readDim)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?() }
            } else if hasMenu {
                // The label is the real text column. A transparent stand-in (what
                // this was) leaves iOS lifting a blank snapshot and tracking the
                // press-and-drag against a contentless full-row button — the menu
                // flickered as the drag left and re-entered it.
                // A `Menu` hides its label while open, which is what made the row's
                // text vanish before, so an identical copy sits behind it and holds
                // the text on screen for as long as the menu is up.
                Menu {
                    contentMenu()
                } label: {
                    textColumn
                } primaryAction: {
                    onOpen?()
                }
                .buttonStyle(.plain)
                .background { textColumn }
                // Dim the pair once: fading each copy separately stacks to ~0.97
                // and read rows stop receding at all.
                .opacity(readDim)
            } else {
                textColumn.opacity(readDim)
            }
        }
        .padding(.vertical, Space.s2)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var avatar: some View {
        let ring = AvatarRing(initials: avatarInitials, size: 48, seed: avatarSeed, email: avatarEmail)
            .overlay(alignment: .bottomTrailing) {
                if let channelBadge {
                    ChannelBadge(channel: channelBadge).offset(x: 3, y: 3)
                }
            }
        if let onAvatarLongPress {
            // Tap opens; hold enters multi-select. The tap target is a Button (not a
            // bare .onTapGesture): a Button fires on touch-up and wins for taps, so a
            // lingering/deliberate tap no longer trips the long-press and drops you
            // into select mode. This restores the NavigationLink-era arbitration —
            // the enclosing NavigationLink was removed (it nested the text column's
            // Menu and hid it on long-press), but only the *text* column has that
            // constraint, so the avatar gets its own Button. The long-press stays a
            // simultaneousGesture (keeps list scrolling alive) and, when it fires,
            // flips edit mode — which swaps this row out before the touch-up, so a
            // hold selects without also opening.
            Button { onOpen?() } label: { ring }
                .buttonStyle(.plain)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                    onAvatarLongPress()
                })
        } else {
            ring
        }
    }

    /// Read rows' text recedes a touch so unread ones (full strength + bold) stand
    /// out; the avatar is excluded so its channel/gradient ring stays vivid.
    /// Applied by the caller, not inside `textColumn` — the menu draws that column
    /// twice (label + stand-in) and two faded copies would barely fade at all.
    private var readDim: Double { convo.unread ? 1 : 0.82 }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Space.s2) {
                Text(displayName)
                    .font(AppFont.sm(convo.unread ? .bold : .medium))
                    .foregroundStyle(convo.unread ? p.textSender : p.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Space.s2)
                Text(displayTime)
                    .font(AppFont.xs2)
                    .foregroundStyle(convo.unread ? p.unread : p.textTertiary)
            }

            Text(convo.subject)
                .font(AppFont.sm(convo.unread ? .bold : .regular))
                .foregroundStyle(convo.unread ? p.textPrimary : p.textSecondary)
                .lineLimit(1)

            HStack(spacing: Space.s2) {
                Text(convo.preview)
                    .font(AppFont.xs)
                    .foregroundStyle(p.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: Space.s2)
                if convo.messageCount > 1 {
                    Text("\(convo.messageCount)")
                        .font(AppFont.xs3)
                        .foregroundStyle(p.textTertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(p.bgElevated))
                }
                if let chip = TriagePriority.chip(convo.triagePriority) {
                    InboxTag(text: chip, color: chip == "Urgent" ? p.statusUrgent : p.statusPending)
                }
                if let triage = convo.triage, let badge = triage.rowBadge {
                    InboxTag(text: badge, color: triageColor(triage))
                } else if let custom = customLabelName {
                    InboxTag(text: custom, color: p.textSecondary)
                } else if let status = convo.badge {
                    InboxTag(text: status.label, color: statusColor(status))
                }
                if convo.unread {
                    Circle().fill(p.unread).frame(width: 8, height: 8)
                }
            }
        }
    }

    /// A custom label's name (any slug that isn't a built-in), from the local list
    /// for channel rows or the org's list for MX rows — a neutral chip.
    private var customLabelName: String? {
        guard convo.triage == nil, let slug = convo.triageLabel, !slug.isEmpty else { return nil }
        return TriageLabelNames.name(for: slug, orgId: convo.isDomain ? convo.accountKey : nil)
    }

    private func statusColor(_ s: ConvStatus) -> Color {
        switch s {
        case .open: return p.statusOpen
        case .pending: return p.statusPending
        case .urgent: return p.statusUrgent
        case .ai: return p.statusAI
        case .archived: return p.statusArchived
        }
    }

    /// Tint for the triage chip, reusing the status palette tokens.
    private func triageColor(_ t: TriageLabel) -> Color {
        switch t {
        case .needsAnswer, .actionRequired, .paymentDue: return p.statusUrgent
        case .needsApproval: return p.statusPending
        case .waitingReply, .needsAnswerOther, .scheduling, .toReview, .readLater: return p.statusOpen
        case .fyi, .resolved, .receipt, .notification: return p.statusArchived
        }
    }
}

extension ConversationRow where ContentMenu == EmptyView {
    init(convo: Conversation, channelBadge: Channel? = nil, isSent: Bool = false, onAvatarLongPress: (() -> Void)? = nil) {
        self.init(convo: convo, channelBadge: channelBadge, isSent: isSent, onAvatarLongPress: onAvatarLongPress, onOpen: nil) { EmptyView() }
    }
}
