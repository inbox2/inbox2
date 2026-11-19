import SwiftUI

/// Pill-style filter tabs (active = elevated pill with a violet edge).
struct FilterPills: View {
    @Environment(\.theme) private var theme
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: Space.s2) {
            ForEach(options, id: \.self) { opt in
                let active = opt == selection
                Text(opt)
                    .font(AppFont.xs(active ? .semibold : .medium))
                    .foregroundStyle(active ? theme.palette.keycapLabel(.selected, or: theme.palette.textPrimary) : theme.palette.textTertiary)
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s2)
                    .background {
                        if active, let key = theme.palette.selectKeycap {
                            Color.clear.keycap(key, radius: Radius.full)
                        } else {
                            Capsule().fill(active ? theme.palette.bgElevated : .clear)
                                .overlay(active ? Capsule().stroke(theme.palette.accentViolet.opacity(0.55), lineWidth: 1) : nil)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = opt } }
            }
            Spacer()
        }
    }
}

/// Enclosed segmented tab bar — an outlined rounded container holding evenly-spaced
/// labels, with the active segment drawn as a raised capsule with a plain hairline.
/// An alternative tab style to `FilterPills`; currently used by the calendar.
struct SegmentedTabs: View {
    @Environment(\.theme) private var theme
    @Binding var selection: String
    let options: [String]

    var body: some View {
        let p = theme.palette
        HStack(spacing: Space.s1) {
            ForEach(options, id: \.self) { opt in
                let active = opt == selection
                // A Button, not a tap gesture, so keyboard focus can reach it (F4).
                Button { withAnimation(.easeOut(duration: 0.18)) { selection = opt } } label: {
                Text(opt)
                    .font(AppFont.sm(active ? .bold : .medium))
                    .foregroundStyle(active ? p.keycapLabel(.selected, or: p.textPrimary) : p.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s2 + 1)
                    .background {
                        if active, let key = p.selectKeycap {
                            Color.clear.keycap(key, radius: Radius.full)
                        } else if active {
                            Capsule(style: .continuous)
                                .fill(p.bgRaised)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(p.borderStrong, lineWidth: 1)
                                )
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(Space.s1 + 1)
        .background(
            Capsule(style: .continuous)
                .fill(p.bgBase.opacity(0.6))
                .overlay(Capsule(style: .continuous).stroke(p.borderDefault, lineWidth: 1))
        )
    }
}

/// Big screen header matching the inbox's unscrolled title: a large small-caps
/// title in the softer secondary gray, an optional leading back chevron (pushed
/// screens) and an optional trailing accessory. Use with the native nav bar hidden.
struct ScreenHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let title: AttributedString
    var showBack: Bool
    @ViewBuilder var trailing: Trailing

    init(_ title: String, showBack: Bool = false, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = AttributedString(title)
        self.showBack = showBack
        self.trailing = trailing()
    }

    /// Styled-title variant (e.g. `inbox2 mx` with the `mx` run in code font).
    init(styled title: AttributedString, showBack: Bool = false, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.showBack = showBack
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Space.s2 + 2) {
            if showBack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(AppFont.lg)
                        .foregroundStyle(theme.palette.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(title)
                .font(AppFont.title.smallCaps())
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s2)
    }
}

/// Shared constants for the app's "card" surface (conversation list, reader panes,
/// calendar). One source so the inset margin is consistent everywhere.
enum CardStyle {
    /// Horizontal margin from the screen edge — kept small to maximize content width.
    static let inset: CGFloat = 4
    /// Groovebox: solid panels sit further in so the grid frames them as gutters.
    static let panelInset: CGFloat = 12
}

/// Inset "card" surface matching the conversation-list card: a raised surface with
/// a soft top glow and a faint light gradient border that's brightest along the top
/// edge. Used for the reader's panes (AI summary + message cards) and the calendar.
/// Applies the shared `CardStyle.inset` horizontal margin itself.
struct InsetCard: ViewModifier {
    @Environment(\.theme) private var theme
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        let p = theme.palette
        if let r = p.panelRadius {
            // Groovebox: a solid island panel — no glow, no bevel.
            content
                .background(p.bgPanel, in: RoundedRectangle(cornerRadius: r, style: .continuous))
                .padding(.horizontal, CardStyle.panelInset)
        } else {
            lit(content, p)
        }
    }

    private func lit(_ content: Content, _ p: ThemePalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(p.bgSurface)
            // Concentrated top glow at a fixed height (not relative to card height,
            // so tall cards keep the same luminous top as the inbox rows).
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color.bevel(0.07), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 72)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            // Crisp bright top edge that quickly settles to a faint side/bottom border.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(stops: [
                        .init(color: .bevel(0.22), location: 0),
                        .init(color: p.borderSubtle, location: 0.10),
                        .init(color: p.borderSubtle, location: 1)
                    ], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
            )
            .padding(.horizontal, CardStyle.inset)
    }
}

extension View {
    func insetCard(radius: CGFloat = 18) -> some View { modifier(InsetCard(radius: radius)) }
    /// Groovebox: frame a loose content block (chart, month grid) as a solid panel
    /// so the grid only shows in the gutters. No-op in other themes.
    func grooveFramed() -> some View { modifier(GrooveFramed()) }
    /// Groovebox: a solid capsule behind loose hint text over the grid. No-op elsewhere.
    func grooveCapsule() -> some View { modifier(GrooveCapsule()) }
    /// Full-screen page ground: `fallback` (default `bgBase`), or the Groovebox
    /// guidebook grid where the theme draws one.
    func pageBackground(_ fallback: Color? = nil) -> some View { modifier(PageBackground(fallback: fallback)) }
}

private struct PageBackground: ViewModifier {
    @Environment(\.theme) private var theme
    let fallback: Color?
    func body(content: Content) -> some View {
        content.background {
            if theme.palette.guidebookGrid {
                GrooveboxScene(shapes: false)
            } else {
                (fallback ?? theme.palette.bgBase).ignoresSafeArea()
            }
        }
    }
}

/// The shared floating-capsule chrome: a solid elevated capsule, one hairline and one
/// soft shadow. One source for every floating affordance — the bottom `FloatingNavBar`,
/// the inbox bulk-action bar, and the undo/send toasts — so they all read as the same
/// family. `colors` tints the hairline where the accent carries meaning (the toasts
/// signal their action by hue); pass `[]` for a plain neutral edge, as the nav does.
struct GlowCapsule: ViewModifier {
    @Environment(\.theme) private var theme
    var colors: [Color] = GlowCapsule.inboxAccent

    /// The inbox tab's purple accent — the default for affordances shown over the inbox
    /// (and the `FloatingNavBar`'s default-tab border). Single source for the hue.
    static let inboxAccent = [ChannelColor.violet, ChannelColor.violetDeep]

    func body(content: Content) -> some View {
        let p = theme.palette
        // Opaque, so the bar reads as a solid object rather than frosted glass.
        let fill = p.floatFill ?? (p.isDark ? p.bgElevated : Color.white)
        // Neutral edge unless the caller passes an accent that carries meaning.
        let edge: AnyShapeStyle = colors.isEmpty
            ? AnyShapeStyle(p.isDark ? Color.bevel(0.09) : Color.scrim(0.12))
            : AnyShapeStyle(LinearGradient(colors: colors.map { $0.opacity(0.55) },
                                           startPoint: .leading, endPoint: .trailing))
        return content
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(edge, lineWidth: 1))
            .shadow(color: .black.opacity(p.isDark ? 0.5 : 0.16),
                    radius: p.isDark ? 18 : 14, y: 8)
    }
}

extension View {
    /// Apply the shared floating-glass capsule chrome (see `GlowCapsule`).
    func glowCapsule(colors: [Color] = GlowCapsule.inboxAccent) -> some View {
        modifier(GlowCapsule(colors: colors))
    }
}

private struct GrooveFramed: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        if let r = theme.palette.panelRadius {
            // Clipped too, so scrolling content (the day timeline) stays inside the corners.
            let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
            content.padding(.vertical, Space.s3)
                .background(theme.palette.bgPanel, in: shape)
                .clipShape(shape)
                .padding(.horizontal, CardStyle.panelInset)
        } else {
            content
        }
    }
}

private struct GrooveCapsule: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        if theme.palette.panelRadius != nil {
            content
                .padding(.horizontal, Space.s4).padding(.vertical, Space.s1 + 2)
                .background(theme.palette.bgPanel, in: Capsule())
        } else {
            content
        }
    }
}
