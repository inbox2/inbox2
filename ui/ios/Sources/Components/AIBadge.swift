import SwiftUI

/// Inline AI classification badge (sentiment / intent), mirroring the desktop
/// AIBadge — color-coded, icon + label, dim accent fill.
struct AIBadge: View {
    @Environment(\.theme) private var theme
    let label: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(AppFont.xs3(.semibold))
            Text(label).font(AppFont.xs3)
        }
        .padding(.horizontal, Space.s2)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.14))
        .clipShape(Capsule())
    }

    // Convenience constructors matching the desktop sentiment/intent palette.
    static func sentiment(positive: Bool, theme: Theme) -> AIBadge {
        positive
            ? AIBadge(label: "Positive", systemImage: "face.smiling", color: theme.palette.accentSuccess)
            : AIBadge(label: "Negative", systemImage: "face.dashed", color: theme.palette.accentDanger)
    }

    static func intent(_ kind: IntentKind, theme: Theme) -> AIBadge {
        let p = theme.palette
        let color: Color
        switch kind {
        case .question: color = p.accentAmber
        case .request: color = p.accentPurple
        case .complaint: color = p.accentDanger
        case .scheduling: color = p.accentTeal
        case .fyi: color = p.accentPrimary
        }
        return AIBadge(label: kind.label, systemImage: kind.systemImage, color: color)
    }
}
