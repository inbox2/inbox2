import ActivityKit
import SwiftUI
import WidgetKit

@main
struct Inbox2WidgetBundle: WidgetBundle {
    var body: some Widget {
        MailLiveActivity()
        ZoneLiveActivity()
        LoreLiveActivity()
        UnreadStackWidget()
    }
}

/// "Next up · Done" for LoreActivityAttributes (docs/Live-Activity.md "Lore"). Same
/// dark card as the mail activity. Done is a real control; a tap on the card opens the email.
struct LoreLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoreActivityAttributes.self) { context in
            LoreCard(state: context.state)
                .activityBackgroundTint(Color(red: 0.035, green: 0.04, blue: 0.055))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "inbox2://conversation/\(context.state.conversationKey)"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { BrandMark(size: 22).padding(.top, 4) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.headline).lineLimit(2)
                        Text(s.sender).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) { LoreDoneRow(state: s) }
            } compactLeading: {
                BrandMark(size: 18)
            } compactTrailing: {
                Text(s.tag).font(.caption2.weight(.semibold))
            } minimal: {
                BrandMark(size: 18)
            }
            .widgetURL(URL(string: "inbox2://conversation/\(s.conversationKey)"))
        }
    }
}

private struct LoreCard: View {
    let state: LoreActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BrandMark(size: 22)
                Text("NEXT UP").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Text(state.tag).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                Spacer(minLength: 8)
                if state.more > 0 { Text("+\(state.more)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Text(state.title).font(.headline).lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.sender).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                LoreDoneRow(state: state)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

private struct LoreDoneRow: View {
    let state: LoreActivityAttributes.ContentState

    var body: some View {
        Button(intent: LoreDoneIntent(state: state)) {
            Label("Done", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// Lock-screen card + Dynamic Island for MailActivityAttributes. Dark, brand-navy
/// surface with the inbox2 blue on the primary action — the app's theme tokens
/// aren't linked into the extension, so the few colours are literal here.
struct MailLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MailActivityAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color(red: 0.035, green: 0.04, blue: 0.055))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(openURL(context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BrandMark(size: 28)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.sender).font(.headline).lineLimit(1)
                        Text(context.state.subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    UnreadPill(count: context.state.unread)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActionRow(state: context.state)
                }
            } compactLeading: {
                BrandMark(size: 18)
            } compactTrailing: {
                Text("\(context.state.unread)").font(.caption.weight(.semibold)).monospacedDigit()
            } minimal: {
                BrandMark(size: 18)
            }
            .widgetURL(openURL(context.state))
        }
    }

    private func openURL(_ state: MailActivityAttributes.ContentState) -> URL? {
        URL(string: "inbox2://conversation/\(state.conversationKey)")
    }
}

private struct LockScreenCard: View {
    let state: MailActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(state.sender).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Date(timeIntervalSince1970: state.receivedAt), style: .relative)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(state.subject).font(.subheadline.weight(.medium)).lineLimit(1)
                    if !state.snippet.isEmpty {
                        Text(state.snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            HStack {
                ActionRow(state: state)
                Spacer(minLength: 0)
                UnreadPill(count: state.unread)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

/// Read / Archive / Trash — the desktop popup's order (NewMessagePopup.jsx), also
/// used by the notification long-press menu.
private struct ActionRow: View {
    let state: MailActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            ActionButton(verb: "mark_read", label: "Read", icon: "envelope.open", state: state, tint: Color.button)
            ActionButton(verb: "archive", label: "Archive", icon: "archivebox", state: state, tint: Color.button)
            ActionButton(verb: "trash", label: "Trash", icon: "trash", state: state, tint: Color.trash)
        }
    }
}

/// The app icon as the card's mark (the extension has no theme runtime or brand
/// vector; `BrandMark.imageset` is the icon master downscaled).
struct BrandMark: View {
    let size: CGFloat

    private var assetName: String {
        let raw = UserDefaults(suiteName: "group.com.inbox2.ios")?
            .string(forKey: "inbox2_active_app_icon") ?? "classic"
        let allowed = ["classic", "sun", "vennlight", "graffiti", "groovebox"]
        return "AppIcon-\(allowed.contains(raw) ? raw : "classic")"
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private struct ActionButton: View {
    let verb: String, label: String, icon: String
    let state: MailActivityAttributes.ContentState
    let tint: Color

    var body: some View {
        Button(intent: MailActivityActionIntent(verb: verb, state: state)) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(tint, in: Capsule())
        }
        .buttonStyle(.plain)
        .tint(.white)
    }
}

/// "+N": the other unread besides the one on the card (badge − 1), button-sized so
/// it reads as the fourth item in the row.
private struct UnreadPill: View {
    let count: Int
    var body: some View {
        if count > 1 {
            Text("+\(count - 1)")
                .font(.caption.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.button, in: Capsule())
        }
    }
}

private extension Color {
    /// Regular dark button on the navy card.
    static let button = Color.white.opacity(0.14)
    /// Destructive red.
    static let trash = Color.red.opacity(0.75)
}

/// "You're in the zone" — countdown card for ZoneActivityAttributes. Same dark card
/// as the mail activity; the zone's colour is the dark-theme tone of its palette key
/// (the app's theme tokens aren't linked here, so they're literal).
struct ZoneLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ZoneActivityAttributes.self) { context in
            ZoneCard(attrs: context.attributes)
                .activityBackgroundTint(Color(red: 0.035, green: 0.04, blue: 0.055))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let a = context.attributes
            let tone = Color.zone(a.colorKey)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BrandMark(size: 22).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name).font(.headline).lineLimit(1)
                        Text(a.category.isEmpty ? "In the zone" : a.category)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: a.start...a.end, countsDown: true)
                        .font(.headline).monospacedDigit().foregroundStyle(tone)
                        .frame(width: 70, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        ProgressView(timerInterval: a.start...a.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                            .tint(tone)
                        ZoneLinks(zoneId: a.zoneId)
                    }
                }
            } compactLeading: {
                BrandMark(size: 18)
            } compactTrailing: {
                Text(timerInterval: a.start...a.end, countsDown: true)
                    .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(tone)
                    .frame(width: 44)
            } minimal: {
                BrandMark(size: 18)
            }
        }
    }
}

private struct ZoneCard: View {
    let attrs: ZoneActivityAttributes

    var body: some View {
        let tone = Color.zone(attrs.colorKey)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BrandMark(size: 22)
                Text((attrs.category.isEmpty ? "Zone" : attrs.category).uppercased())
                    .font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(tone)
                Spacer(minLength: 8)
                Text(timerInterval: attrs.start...attrs.end, countsDown: true)
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            Text("You're in the zone").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attrs.name).font(.headline).lineLimit(1)
                    if !attrs.note.isEmpty {
                        Text(attrs.note).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                ZoneLinks(zoneId: attrs.zoneId)
            }
            ProgressView(timerInterval: attrs.start...attrs.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(tone)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

/// "Done · Open calendar" as plain secondary text, not buttons — deliberately
/// low-key. Done dismisses the zone (same store as the in-app card) and ends the
/// card; Open deep-links to the Calendar tab. Real controls, 44pt targets.
private struct ZoneLinks: View {
    let zoneId: String

    var body: some View {
        HStack(spacing: 0) {
            Button(intent: ZoneDoneIntent(zoneId: zoneId)) { label("Done") }
                .buttonStyle(.plain)
            Text("·")
            Link(destination: URL(string: "inbox2://calendar")!) { label("Open calendar") }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private func label(_ title: String) -> some View {
        Text(title).padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }
}

private extension Color {
    /// Dark-theme zone tones (ThemePalette.darkZoneTones) — the card is always dark.
    static func zone(_ key: String) -> Color {
        switch key {
        case "amber": return Color(red: 0xd9 / 255, green: 0xa4 / 255, blue: 0x41 / 255)
        case "violet": return Color(red: 0x9a / 255, green: 0x8c / 255, blue: 0xc0 / 255)
        case "green": return Color(red: 0x6f / 255, green: 0xb0 / 255, blue: 0x8a / 255)
        case "rose": return Color(red: 0xd9 / 255, green: 0x8a / 255, blue: 0x9a / 255)
        case "teal": return Color(red: 0x5f / 255, green: 0xb3 / 255, blue: 0xb3 / 255)
        default: return Color(red: 0x5b / 255, green: 0x8d / 255, blue: 0xef / 255)
        }
    }
}
