import SwiftUI

/// Floating capsule bottom nav: a flat pill holding five equal actions — the four
/// tabs plus Compose sitting in the middle as a peer, same chip, same size. The
/// selected tab is a solid violet pill that widens to carry its label; everything
/// else is a dimmed round chip. No halo, no gradient border, no per-tab recolouring
/// of the bar: violet on this bar means exactly one thing, "selected".
struct FloatingNavBar: View {
    @Environment(\.theme) private var theme
    @Binding var selection: Int
    let items: [(icon: String, label: String)]
    var onCompose: (() -> Void)? = nil

    private var p: ThemePalette { theme.palette }

    var body: some View {
        let mid = items.count / 2
        HStack(spacing: Space.s1) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                if idx == mid, onCompose != nil { composeButton }
                navButton(idx, item)
            }
        }
        .padding(.horizontal, Space.s1 + 2)
        .padding(.vertical, Space.s1 + 2)
        .glowCapsule(colors: [])
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: selection)
    }

    /// Rainbow-tabs colour for an on-screen slot (Compose sits at `items.count / 2`).
    private func tabColor(slot: Int) -> Color? {
        guard let colors = p.navTabColors, !colors.isEmpty else { return nil }
        return colors[slot % colors.count]
    }

    private func navButton(_ idx: Int, _ item: (icon: String, label: String)) -> some View {
        let active = idx == selection
        let mid = items.count / 2
        let tint = tabColor(slot: idx >= mid && onCompose != nil ? idx + 1 : idx)
        // Rainbow tabs: the selected tab is a dark keycap; only its icon carries the colour.
        let key = tint != nil ? p.secondaryKeycap : p.selectKeycap
        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { selection = idx }
        } label: {
            HStack(spacing: Space.s2 - 1) {
                Image(systemName: item.icon)
                    .font(AppFont.title2)
                    .foregroundStyle(active ? (tint ?? key?.label ?? p.onAccent) : p.textSecondary)
                if active {
                    Text(item.label)
                        .font(AppFont.glyph(13.5, .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            // Idle chips sit on textSecondary and are dimmed further, so the lit
            // violet pill is the only thing on the bar carrying full contrast.
            .foregroundStyle(active ? (key?.label ?? p.onAccent) : p.textSecondary)
            // 0.55 over the light bar's white fill read as disabled — light mode
            // keeps more ink (the desktop chrome's ~0.62-black inactive weight).
            // Rainbow tabs: only the selected tab carries its section colour.
            .opacity(active ? 1 : (p.isDark ? 0.55 : 0.78))
            .padding(.horizontal, active ? Space.s4 - 2 : 0)
            .frame(width: active ? nil : 48, height: 48)
            .background {
                // Groovebox: the selected tab is a cream keycap, not a violet pill.
                if active, let key {
                    Color.clear.keycap(key, radius: Radius.full)
                } else {
                    Capsule().fill(active ? p.accentViolet : .clear)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    /// Compose is an action, not a tab: it never takes the violet pill, so it renders
    /// as a permanently-idle chip identical to the unselected tabs.
    @ViewBuilder private var composeButton: some View {
        if let onCompose {
            Button { onCompose() } label: {
                Image(systemName: "square.and.pencil")
                    .font(AppFont.title2)
                    .foregroundStyle(p.textSecondary)
                    .opacity(p.isDark ? 0.55 : 0.78)
                    .frame(width: 48, height: 48)
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
    }
}
