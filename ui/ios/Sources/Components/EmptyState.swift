import SwiftUI

/// An SF Symbol painted in the brand ring gradient with a soft neon halo — the shared
/// empty/zero-state hero glyph. No baked background, so it floats cleanly in *both* dark
/// and light (the old raster art baked the `#090a0e` base, which read as a dark tile in
/// light mode).
struct GradientGlyph: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    var size: CGFloat = 72

    var body: some View {
        let p = theme.palette
        Image(systemName: systemImage)
            .font(AppFont.glyph(size))
            .foregroundStyle(LinearGradient(colors: p.ringColors,
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            // Soft neon glow stands in for the old baked halo — reads on both the dark
            // base and a light surface, where a tile would not.
            .shadow(color: (p.ringColors.dropFirst().first ?? p.accentViolet).opacity(0.35), radius: size * 0.25)
    }
}

/// Reusable empty/zero-state — hero glyph, title, message. Mirrors the desktop empty
/// states (no results, empty inbox).
struct EmptyState: View {
    @Environment(\.theme) private var theme
    let systemImage: String
    let title: String
    let message: String

    private var p: ThemePalette { theme.palette }

    var body: some View {
        VStack(spacing: Space.s3) {
            GradientGlyph(systemImage: systemImage)
                .frame(height: 96)
                .padding(.bottom, Space.s2)
            Text(title)
                .font(AppFont.lg)
                .foregroundStyle(p.textPrimary)
            Text(message)
                .font(AppFont.sm)
                .foregroundStyle(p.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.s8)
        .background(p.bgBase)
    }
}
