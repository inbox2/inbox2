import SwiftUI
import WidgetKit

/// "Unread": the home-screen stack (LiveActivity/UnreadStack.swift). The app writes
/// the snapshot and reloads this timeline after every inbox change and every button.
struct UnreadStackWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: UnreadStack.kind, provider: UnreadStackProvider()) { entry in
            UnreadStackView(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { StackColor.ground }
        }
        .configurationDisplayName("Unread")
        .description("Work through your unread mail.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct UnreadStackEntry: TimelineEntry {
    let date: Date
    let snapshot: UnreadStackSnapshot
}

struct UnreadStackProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnreadStackEntry { .init(date: .now, snapshot: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (UnreadStackEntry) -> Void) {
        let s = UnreadStack.load()
        completion(.init(date: .now, snapshot: context.isPreview && s.items.isEmpty ? Self.sample : s))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadStackEntry>) -> Void) {
        // ponytail: .never — the app reloads us; add a refresh policy if the stack goes stale.
        completion(Timeline(entries: [.init(date: .now, snapshot: UnreadStack.load())], policy: .never))
    }

    /// Widget gallery only.
    private static let sample = UnreadStackSnapshot(items: [
        .init(id: "sample", accountKey: "", orgId: "", sender: "Sara Jansen", initials: "SJ", seed: 2,
              subject: "Contract renewal for next year",
              snippet: "Can you check the new terms before Friday?",
              receivedAt: Date().timeIntervalSince1970, canMove: true, canSnooze: true),
    ], unread: 5)
}

private enum StackColor {
    static let ground = Color(red: 0.035, green: 0.04, blue: 0.055)
    static let card = Color(red: 0x25 / 255, green: 0x2a / 255, blue: 0x34 / 255)
    static let back1 = Color(red: 0x1c / 255, green: 0x20 / 255, blue: 0x28 / 255)
    static let back2 = Color(red: 0x15 / 255, green: 0x18 / 255, blue: 0x1e / 255)
    static let secondary = Color(red: 0xb9 / 255, green: 0xbf / 255, blue: 0xcc / 255)
    static let read = Color(red: 120 / 255, green: 130 / 255, blue: 150 / 255).opacity(0.35)
    static let archive = Color(red: 0x3a / 255, green: 0x6b / 255, blue: 0xd1 / 255)
    static let later = Color(red: 0xbe / 255, green: 0x84 / 255, blue: 0x1e / 255)
    static let trash = Color(red: 0xc4 / 255, green: 0x35 / 255, blue: 0x3a / 255)
    /// Sender avatars, picked by `seed`.
    static let avatars: [Color] = [0x9a8cc0, 0x6fb08a, 0x5fb3b3, 0xd9a441, 0xd98a9a, 0x5b8def].map {
        Color(red: Double(($0 >> 16) & 0xff) / 255, green: Double(($0 >> 8) & 0xff) / 255, blue: Double($0 & 0xff) / 255)
    }
}

private struct UnreadStackView: View {
    let snapshot: UnreadStackSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let top = snapshot.items.first {
                if family == .systemLarge { large(top) } else { medium(top) }
            } else {
                HStack(spacing: 12) {
                    BrandMark(size: 40)
                    Text("No unread mail.").font(.headline)
                }
            }
        }
        .foregroundStyle(.white)
        .widgetURL(snapshot.items.first.flatMap { URL(string: "inbox2://conversation/\($0.id)") })
    }

    private var behind: Int { min(snapshot.items.count - 1, 2) }

    private func large(_ top: UnreadStackItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BrandMark(size: 22)
                Text("inbox2").font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(snapshot.unread) unread").font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(StackColor.secondary)
            }
            StackCard(item: top, behind: behind, compact: false)
            ActionButtons(item: top, iconSize: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text("Move to").font(.caption2.weight(.semibold)).foregroundStyle(StackColor.secondary)
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow { chip(.doFirst, top); chip(.schedule, top) }
                    GridRow { chip(.delegate, top); chip(.later, top) }
                }
            }
            .opacity(top.canMove ? 1 : 0.35)
        }
    }

    private func medium(_ top: UnreadStackItem) -> some View {
        VStack(spacing: 8) {
            StackCard(item: top, behind: min(behind, 1), compact: true, unread: snapshot.unread)
            ActionButtons(item: top, iconSize: 15)
        }
    }

    @ViewBuilder
    private func chip(_ q: Quadrant, _ item: UnreadStackItem) -> some View {
        let label = Label(q.label, systemImage: q.systemImage)
            .font(.caption.weight(.medium)).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 10)
            .background(StackColor.back1, in: Capsule())
        if item.canMove {
            Button(intent: UnreadStackIntent(verb: "set_quadrant:\(q.rawValue)", item: item)) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// The top card with up to two cards showing underneath.
private struct StackCard: View {
    let item: UnreadStackItem
    let behind: Int
    let compact: Bool
    var unread: Int? = nil

    var body: some View {
        let step: CGFloat = compact ? 8 : 8
        ZStack(alignment: .top) {
            if behind >= 2 { RoundedRectangle(cornerRadius: 14).fill(StackColor.back2).padding(.horizontal, 16).offset(y: step * 2) }
            if behind >= 1 { RoundedRectangle(cornerRadius: 14).fill(StackColor.back1).padding(.horizontal, 8).offset(y: step) }
            card
        }
        .padding(.bottom, step * CGFloat(behind))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack(spacing: 8) {
                if compact {
                    BrandMark(size: 18)
                } else {
                    Text(item.initials).font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.04, green: 0.05, blue: 0.07))
                        .frame(width: 22, height: 22)
                        .background(StackColor.avatars[abs(item.seed) % StackColor.avatars.count], in: Circle())
                }
                Text(item.sender).font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if let unread {
                    Text("\(unread) unread").font(.caption2.weight(.semibold)).monospacedDigit()
                } else {
                    stamp.font(.caption2)
                }
            }
            .foregroundStyle(.white)
            Text(item.subject).font(compact ? .caption.weight(.medium) : .footnote.weight(.medium)).lineLimit(1)
            if !item.snippet.isEmpty {
                Text(item.snippet).font(compact ? .caption2 : .caption).lineLimit(compact ? 1 : 2)
                    .foregroundStyle(StackColor.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(compact ? 10 : 12)
        .background(StackColor.card, in: RoundedRectangle(cornerRadius: compact ? 12 : 14))
    }

    private var stamp: Text {
        let d = Date(timeIntervalSince1970: item.receivedAt)
        return Calendar.current.isDateInToday(d)
            ? Text(d, style: .time)
            : Text(d, format: .dateTime.day().month(.abbreviated))
    }
}

/// Read / Archive / In 3 h / Trash, each its own glass colour.
private struct ActionButtons: View {
    let item: UnreadStackItem
    let iconSize: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            button("Read", "envelope.open", MailVerb.markRead, StackColor.read)
            button("Archive", "archivebox", MailVerb.archive, StackColor.archive)
            button("In 3 h", "clock", item.canSnooze ? UnreadStack.snoozeVerb : nil, StackColor.later)
            button("Trash", "trash", MailVerb.trash, StackColor.trash)
        }
    }

    @ViewBuilder
    private func button(_ title: String, _ icon: String, _ verb: String?, _ tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let face = VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: iconSize, weight: .semibold))
            Text(title).font(.caption2.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(tint, in: shape)
        .glassEffect(.clear.interactive(), in: shape)
        if let verb {
            Button(intent: UnreadStackIntent(verb: verb, item: item)) { face }.buttonStyle(.plain)
        } else {
            face.opacity(0.35)
        }
    }
}
