import SwiftUI

/// A non-editing inbox row with its actions attached: the long-press context menu on
/// the text column (read aloud / forward / read / move / snooze / file) and the
/// leading + trailing swipe actions. Pure presentation — every action calls back to
/// the list, which owns the optimistic row mutations and undo.
struct ConversationRowActions: View {
    @Environment(\.theme) private var theme
    let convo: Conversation
    var channelBadge: Channel?
    var isSent: Bool
    /// A Forward is downloading attachments: for THIS row the menu reads "Preparing…",
    /// and every row's Forward is disabled until it lands.
    var preparingForwardId: String?
    let onAvatarLongPress: () -> Void
    let onOpen: () -> Void
    let onReadAloud: () -> Void
    let onForward: () -> Void
    /// Undo-able action (swipe / menu file + read toggles).
    let onAct: (ConversationAction) -> Void
    /// Fire-and-forget triage move (no undo toast).
    let onQuick: (ConversationAction) -> Void
    let onSnooze: (Date) -> Void
    private var p: ThemePalette { theme.palette }

    var body: some View {
        // A single guarded open() is the only navigation path, reached two ways: the
        // avatar's onTapGesture and the text column's Menu primaryAction (both ->
        // onOpen). The row is NOT wrapped in a Button/NavigationLink — that would nest
        // the text column's Menu inside another control and hide it on long-press
        // (the cell text vanished).
        ConversationRow(convo: convo, channelBadge: channelBadge, isSent: isSent,
                        onAvatarLongPress: onAvatarLongPress, onOpen: onOpen) { rowMenu }
        // First action = closest to the edge AND the full-swipe target: a full
        // swipe-left archives; the partial reveal reads Trash · Archive.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { onAct(.archive) } label: { swipeLabel("Archive", "archivebox", gradient: true) }
                .tint(.black)
            Button { onAct(.trash) } label: { swipeLabel("Trash", "trash") }
                .tint(.black)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let toRead = convo.unread
            Button { onAct(toRead ? .markRead : .markUnread) } label: {
                swipeLabel(toRead ? "Read" : "Unread", toRead ? "envelope.open" : "envelope.badge")
            }
            .tint(.black)
        }
    }

    /// Long-press context menu on a conversation row's text column — the same triage
    /// actions as the reader's overflow menu, so you can flag / spam / move-to-quadrant
    /// or archive/trash without opening the thread. No Select item: holding the avatar
    /// enters multi-select directly. Destructive/removing verbs animate the row out;
    /// toggles (flag, read, quadrant) leave it in place and let the next re-query
    /// reflect state.
    @ViewBuilder private var rowMenu: some View {
        // Read it aloud + arm voice triage (trash / archive) right here on the list,
        // the same flow as the reader's speaker button.
        Button(action: onReadAloud) {
            Label("Read aloud", systemImage: "speaker.wave.2.fill")
        }

        // Forward the thread's latest message (with its attachments) — opens the
        // composer once the bytes are downloaded.
        Button(action: onForward) {
            Label(preparingForwardId == convo.id ? "Preparing…" : "Forward",
                  systemImage: "arrowshape.turn.up.right")
        }
        .disabled(preparingForwardId != nil)
        Divider()

        let toRead = convo.unread
        Button {
            onAct(toRead ? .markRead : .markUnread)
        } label: {
            Label(toRead ? "Mark as read" : "Mark as unread",
                  systemImage: toRead ? "envelope.open" : "envelope.badge")
        }

        // Triage quadrants are engine-only (domain uses tags/assignment). inbox2 has
        // no flag concept — triage is the move affordance.
        if convo.supportsTriage {
            Menu {
                ConversationMenus.triageItems { onQuick($0) }
            } label: {
                Label("Move to", systemImage: "tray.full")
            }
        }

        if convo.supportsSnooze {
            Menu {
                ConversationMenus.snoozeItems { onSnooze($0) }
            } label: { Label("Snooze", systemImage: "clock.badge") }
        }

        Divider()

        // In spam/trash/archived, lead with "Move to Inbox" and drop the redundant
        // removal item that matches the current status (no "Trash" while in Trash).
        if let restore = convo.restoreAction {
            Button { onAct(restore) } label: {
                Label("Move to Inbox", systemImage: "tray.and.arrow.down")
            }
        }
        if convo.status != ConvStatusValue.archived {
            Button { onAct(.archive) } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
        // Spam sits above Trash and stays a plain (non-destructive) item on every
        // channel: it's a filing move — the domain trains Rspamd, offline channels
        // move it to the provider's junk folder. Only Trash reads red.
        if convo.status != ConvStatusValue.spam {
            Button { onAct(.spam) } label: {
                Label("Mark as spam", systemImage: "exclamationmark.octagon")
            }
        }
        if convo.status != ConvStatusValue.trash {
            Button(role: .destructive) { onAct(.trash) } label: {
                Label("Trash", systemImage: "trash")
            }
        }
    }

    /// Swipe-action label on a black tile. `gradient` paints the glyph in the ring
    /// gradient (the hero Archive action); otherwise it's a soft off-white. Native
    /// swipe actions flatten a SwiftUI `foregroundStyle` to a solid tint, so the glyph
    /// is pre-rendered into an `.original` image either way (keeps sizing identical).
    private func swipeLabel(_ title: String, _ system: String, gradient: Bool = false) -> some View {
        let whiteish = UIColor(white: 0.92, alpha: 1)
        let colors = gradient ? p.ringColors.map(UIColor.init) : [whiteish, whiteish]
        return Label {
            Text(title)
        } icon: {
            if let img = UIImage.gradientSymbol(system, colors: colors) {
                Image(uiImage: img)
            } else {
                Image(systemName: system)
            }
        }
    }
}
