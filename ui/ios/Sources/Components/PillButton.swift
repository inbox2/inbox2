import SwiftUI

/// The one small tinted-capsule action ("Send now", "+3 more", "Reconnect"), so the
/// padding, fill and press feedback don't drift between hand-rolled copies.
/// `.tint` is the quiet dim-fill pill; `.outlined` adds a stroke and primary ink for
/// a call to action that must read on a tinted banner.
struct PillButton: View {
    enum Style { case tint, outlined }
    @Environment(\.theme) private var theme
    let title: String
    let tint: Color
    var style: Style = .tint
    /// A row action needs the 44pt target the small capsule doesn't have: the
    /// capsule stays the same size, the tappable frame around it grows.
    var minHitHeight: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        let p = theme.palette
        Button(action: action) {
            Text(title)
                .font(AppFont.xs2(.semibold))
                .foregroundStyle(style == .outlined ? p.textPrimary : tint)
                .padding(.horizontal, Space.s2 + 2)
                .padding(.vertical, Space.s1 + 1)
                .background(Capsule().fill(tint.opacity(style == .outlined ? 0.22 : 0.14)))
                .overlay(Capsule().stroke(tint.opacity(style == .outlined ? 0.45 : 0), lineWidth: 1))
                .frame(minHeight: minHitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}
