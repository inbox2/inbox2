import SwiftUI

/// The hands-free triage prompt shown during the read-aloud listen window — a pulsing
/// listening orb over the keywords on offer. Tapping it dismisses the prompt (same as
/// letting the window time out, or saying "no"). Shared by the message reader and the
/// inbox row "Read aloud" so both read the same.
struct TriageListeningPill: View {
    @Environment(\.theme) private var theme
    /// Live mic level for the orb.
    var level: Double
    /// Dismiss the prompt (tap to cancel).
    var onTap: () -> Void
    private var p: ThemePalette { theme.palette }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Space.s2) {
                VoiceOrb(size: 24, level: level, colors: [kPink, p.accentViolet])
                    .padding(.trailing, Space.s2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Listening…").font(AppFont.xs(.semibold)).foregroundStyle(p.textPrimary)
                    Text("trash · archive").font(AppFont.xs2).foregroundStyle(p.textTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, Space.s4).padding(.vertical, Space.s2 + 2)
            .background(Capsule(style: .continuous).fill(p.bgRaised.opacity(0.92)))
            .overlay(Capsule(style: .continuous).stroke(p.borderStrong, lineWidth: 1))
            .shadow(color: kPink.opacity(0.3), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Self-contained presenter for `TriageListeningPill`: shows it while the shared
/// read-aloud controller is in its listening window, sourcing the live mic level from
/// `AudioLevels`. Owning the high-frequency `mic` observation here means the host (the
/// inbox list or the open reader) only re-renders on the low-frequency `phase`, never on
/// every mic frame — so the level can't flicker the screen behind it.
struct ReadAloudListeningPill: View {
    /// Scope to a specific thread (the reader) — nil shows for any active read (inbox).
    var conversationId: String? = nil
    @EnvironmentObject private var readAloud: ReadAloudController
    @ObservedObject private var levels = AudioLevels.shared

    private var listening: Bool {
        guard readAloud.phase == .listening else { return false }
        guard let id = conversationId else { return true }
        return readAloud.isActive(id)
    }

    var body: some View {
        if listening {
            TriageListeningPill(level: levels.mic) { readAloud.stop() }
        }
    }
}
