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

                    if let metaFolders {
                        // Meta account: channel/kind sub-views (no mail folders / triage).
                        ForEach(metaFolders) { folderRow($0) }
                    } else {
                        ForEach(MailFolder.mailboxes) { folderRow($0) }

                        Text("TRIAGE")
                            .font(AppFont.xs2(.semibold)).tracking(0.8)
                            .foregroundStyle(p.textTertiary)
                            .padding(.horizontal, Space.s5)
                            .padding(.top, Space.s5).padding(.bottom, Space.s2)
                        ForEach(MailFolder.triage) { folderRow($0) }
                    }

                    Spacer()
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
        let active = folder == selection
        // Triage folders carry their own desktop quadrant tint (always coloured, like
        // the desktop matrix); standard mailboxes use the violet active treatment.
        let tint = folder.tintHex.map { Color(hex: $0) }
        let accent = tint ?? p.accentViolet
        return Button {
            selection = folder
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

    private func close() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { isPresented = false }
    }
}
