import SwiftUI

/// Activity / notifications — a real feed of recent inbound mail across all
/// accounts, styled after the reference (rounded rows, gradient avatars, violet
/// action pills). Tapping a row opens the conversation in the reader. Reads live
/// from the local store and refreshes on engine sync/new-message events.
struct ActivityView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @State private var items: [ActivityEntry] = []
    private var p: ThemePalette { theme.palette }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScreenHeader("Activity")
                Group {
                if items.isEmpty {
                    EmptyState(systemImage: "clock.arrow.circlepath", title: "No activity",
                               message: "Recent mail across your accounts shows up here.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s3) {
                            ForEach(items) { item in
                                NavigationLink(value: item) { row(item) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(Space.s4)
                    }
                }
            }
            }
            .background(p.bgBase.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 70) }
            .navigationDestination(for: ActivityEntry.self) { entry in
                ActivityConversationDestination(key: entry.conversationKey)
            }
            .task(id: engine.dataVersion) {
                let result = await engine.store.read { $0.recentActivity() }
                guard !Task.isCancelled else { return }
                items = result
            }
        }
    }

    private func row(_ item: ActivityEntry) -> some View {
        HStack(spacing: Space.s3) {
            AvatarRing(initials: item.initials, size: 44, seed: item.seed, email: MailAddress.parse(item.fromAddress).email)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(AppFont.sm(item.unread ? .semibold : .regular))
                    .foregroundStyle(p.textPrimary).lineLimit(2)
                Text(item.time).font(AppFont.xs2).foregroundStyle(p.textTertiary)
            }
            Spacer(minLength: Space.s2)
            Text("Open")
                .font(AppFont.xs(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Space.s3)
                .padding(.vertical, Space.s1 + 2)
                .background(
                    LinearGradient(colors: [p.accentViolet, p.accentViolet.opacity(0.82)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .clipShape(Capsule())
        }
        .padding(Space.s3)
        .background(p.bgSurface)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .stroke(p.borderDefault, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}

/// Loads the tapped conversation off the main actor (a store read inside
/// `navigationDestination` would block the push animation), then hands it to
/// `MessageView`; shows the "gone" state once the read comes back empty.
private struct ActivityConversationDestination: View {
    let key: String
    @EnvironmentObject private var engine: EngineModel
    @State private var convo: Conversation?
    @State private var loaded = false

    var body: some View {
        Group {
            if let convo {
                MessageView(convo: convo)
            } else if loaded {
                EmptyState(systemImage: "magnifyingglass", title: "Unavailable",
                           message: "This conversation is no longer in your inbox.")
            } else {
                ProgressView()
            }
        }
        .task(id: key) {
            let result = await engine.store.read { $0.conversation(key: key) }
            guard !Task.isCancelled else { return }
            convo = result
            loaded = true
        }
    }
}
