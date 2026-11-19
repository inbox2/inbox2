import SwiftUI

/// On-device AI thread summary card, mirroring the desktop AISummaryPanel — a
/// teal-tinted card with bullet points above the message body.
struct AISummaryPanel: View {
    @Environment(\.theme) private var theme
    let bullets: [String]
    /// AI-derived signals shown alongside the summary (per the design).
    var sentimentPositive: Bool? = nil
    var intentKind: IntentKind? = nil
    /// Collapsed by default; tapping the header expands/collapses.
    @State private var expanded = false
    private var p: ThemePalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: Space.s1 + 2) {
                    Image(systemName: "sparkles").font(AppFont.xs2).foregroundStyle(p.accentTeal)
                    Text("AI summary").font(AppFont.xs(.semibold)).foregroundStyle(p.textSecondary)
                    Spacer(minLength: Space.s2)
                    if let sentimentPositive { AIBadge.sentiment(positive: sentimentPositive, theme: theme) }
                    if let intentKind { AIBadge.intent(intentKind, theme: theme) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(AppFont.xs3(.semibold))
                        .foregroundStyle(p.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: Space.s2) {
                            Text("•").foregroundStyle(p.accentTeal)
                            Text(bullet)
                                .font(AppFont.mono(12))
                                .foregroundStyle(p.textPrimary)
                        }
                    }
                }
                .padding(.top, Space.s1 + 2)
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetCard()
    }
}
