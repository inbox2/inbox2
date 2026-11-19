import SwiftUI

/// Outbox (queued / failed sends) list section — read live from `outbox_messages`.
/// The engine auto-retries pending rows, so this is primarily a status surface:
/// failed sends show their error in red with a "Send now" re-queue. Swipe a row to
/// cancel (delete) a stuck send. Split out of `InboxListView`; the row chrome comes
/// in via `cardBackground` and the actions via closures.
struct OutboxListSection: View {
    @Environment(\.theme) private var theme
    let outbox: [OutboxItem]
    let cardBackground: (_ first: Bool, _ last: Bool) -> AnyView
    let onCancel: (OutboxItem) -> Void
    let onRetry: (OutboxItem) -> Void
    private var p: ThemePalette { theme.palette }

    var body: some View {
        if outbox.isEmpty {
            EmptyState(systemImage: "tray.and.arrow.up", title: "Outbox empty",
                       message: "Messages waiting to send show up here.")
                .frame(maxWidth: .infinity).padding(.top, Space.s8)
                .plainListRow()
        } else {
            ForEach(Array(outbox.enumerated()), id: \.element.id) { idx, item in
                row(item)
                    .cardListRow(background: cardBackground(idx == 0, idx == outbox.count - 1))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { onCancel(item) } label: { Label("Cancel", systemImage: "trash") }
                    }
            }
        }
    }

    private func row(_ item: OutboxItem) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: item.isFailed ? "exclamationmark.triangle.fill"
                  : (item.isSending ? "paperplane.fill" : "clock"))
                .font(AppFont.lg(.regular))
                .foregroundStyle(item.isFailed ? p.accentDanger : p.accentViolet)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.recipient).font(AppFont.sm(.semibold)).foregroundStyle(p.textPrimary).lineLimit(1)
                    Spacer()
                    Text(item.time).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                }
                Text(item.subject).font(AppFont.xs).foregroundStyle(p.textSecondary).lineLimit(1)
                HStack(spacing: Space.s2) {
                    Text(item.statusLine)
                        .font(AppFont.xs2)
                        .foregroundStyle(item.isFailed ? p.accentDanger : p.textTertiary)
                    if item.isFailed, let err = item.errorMessage, !err.isEmpty {
                        Text("· \(err)").font(AppFont.xs2).foregroundStyle(p.accentDanger.opacity(0.85)).lineLimit(1)
                    }
                }
            }
            // Failed sends have exhausted auto-retry; offer a manual re-queue.
            if item.isFailed {
                PillButton(title: "Send now", tint: p.accentViolet) { onRetry(item) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Local drafts list (the Drafts folder) — tap to resume, swipe to delete. Split out
/// of `InboxListView`; the row chrome comes in via `cardBackground` and the actions
/// via closures.
struct DraftsListSection: View {
    @Environment(\.theme) private var theme
    let drafts: [SavedDraft]
    let cardBackground: (_ first: Bool, _ last: Bool) -> AnyView
    let onResume: (SavedDraft) -> Void
    let onDelete: (UUID) -> Void
    private var p: ThemePalette { theme.palette }

    var body: some View {
        if drafts.isEmpty {
            EmptyState(systemImage: "doc.text", title: "No drafts", message: "Drafts you save show up here.")
                .frame(maxWidth: .infinity).padding(.top, Space.s8)
                .plainListRow()
        } else {
            ForEach(Array(drafts.enumerated()), id: \.element.id) { idx, d in
                Button { onResume(d) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.titleLine).font(AppFont.sm(.semibold)).foregroundStyle(p.textPrimary).lineLimit(1)
                        Text(d.previewLine).font(AppFont.xs).foregroundStyle(p.textTertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cardListRow(background: cardBackground(idx == 0, idx == drafts.count - 1))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { onDelete(d.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
}
