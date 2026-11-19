import SwiftUI

/// A thin capsule progress bar filled with the app ring gradient. Shared by the
/// Settings "Triage & sync" panel and the Bridge target area to show how far the
/// background triage/summary worker has gotten through the in-window backlog.
struct TriageProgressBar: View {
    @Environment(\.theme) private var theme
    /// 0…1 completion.
    var progress: Double
    /// Optional caption above the bar (e.g. "Classifying 1,204 of 3,500").
    var caption: String?
    /// Optional right-aligned value on the caption row (e.g. the date being processed).
    var trailing: String? = nil

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: Space.s1) {
            if caption != nil || trailing != nil {
                HStack(spacing: Space.s2) {
                    if let caption {
                        Text(caption)
                            .font(AppFont.xs2)
                            .foregroundStyle(p.textTertiary)
                    }
                    Spacer(minLength: Space.s2)
                    if let trailing {
                        Text(trailing)
                            .font(AppFont.xs2)
                            .monospacedDigit()
                            .foregroundStyle(p.textSecondary)
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.bgRaised)
                    Capsule()
                        .fill(LinearGradient(colors: p.ringColors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, min(1, progress)) * geo.size.width)
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
        }
    }
}
