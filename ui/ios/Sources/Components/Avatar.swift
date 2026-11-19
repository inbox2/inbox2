import SwiftUI

/// Circular avatar with initials fallback (desktop Avatar). A deterministic accent
/// tint per identity keeps the list scannable.
struct Avatar: View {
    @Environment(\.theme) private var theme
    let initials: String
    var size: CGFloat = 38
    var seed: Int = 0

    private var tint: Color {
        let p = theme.palette
        let palette = [p.accentPrimary, p.accentTeal, p.accentAmber, p.accentPurple, p.accentSuccess, p.accentWarm]
        return palette[abs(seed) % palette.count]
    }

    var body: some View {
        Text(initials)
            .font(AppFont.glyph(size * 0.38, .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16))
            .clipShape(Circle())
            .overlay(Circle().stroke(theme.palette.borderDefault, lineWidth: 1))
    }
}
