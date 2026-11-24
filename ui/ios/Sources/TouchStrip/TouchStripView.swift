import SwiftUI

/// The Touch Strip for the iPad (docs/Touch-Strip.md; port of `TouchStrip.jsx`):
/// one 55pt translucent panel of flat keys split by hairlines. Tap a key and its
/// full-width view replaces the keys; ✕ (or Esc) returns. Pinned or hidden
/// (`TouchStripModel.mode`, remembered under "ipad.touchStrip"); hidden collapses
/// to a small edge tab that reopens it.
///
/// Mount at the bottom of a shell: `.safeAreaInset(edge: .bottom, spacing: 0) { TouchStripView() }`.
struct TouchStripView: View {
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var model = TouchStripModel.shared
    @State private var expanded: StripWidget?
    @State private var customizing = false
    /// The on-screen keyboard is up: the strip steps aside rather than ride above it
    /// (a hardware keyboard shows none, so the strip stays).
    @State private var keyboardUp = false

    private var p: ThemePalette { theme.palette }
    /// The window's home-indicator inset (the view's own would shrink as it moves down).
    private var bottomInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        Group {
            if keyboardUp { EmptyView() } else if model.mode == .hidden { edgeTab } else { bar }
        }
        // Into the home-indicator band: the strip sat a full inset above the edge,
        // leaving an empty band under it. A few points stay clear of the indicator.
        .padding(.bottom, -max(0, bottomInset - 6))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onChange(of: scenePhase, initial: true) { StripFeedStore.shared.active = scenePhase != .background }
        .sheet(isPresented: $customizing) { TouchStripCustomize() }
    }

    private var open: StripWidget? {
        guard let expanded, model.config.items.contains(expanded) else { return nil }
        return expanded
    }

    private var bar: some View {
        HStack(spacing: 0) {
            if let open {
                StripIconButton(icon: "xmark", label: "Close \(open.label)") { expanded = nil }
                    .keyboardShortcut(.cancelAction)
                    .padding(.horizontal, 10)
                StripDivider()
                StripRow { StripWidgetView(id: open, config: model.config, expanded: true) }
            } else {
                StripIconButton(icon: "chevron.down", label: "Hide Touch Strip") { model.mode = .hidden }
                    .padding(.horizontal, 10)
                StripDivider()
                StripRow {
                    ForEach(model.config.items) { id in
                        StripWidgetView(id: id, config: model.config, onExpand: id.expands ? { expanded = id } : nil)
                    }
                    if model.config.items.isEmpty {
                        Text("The strip is empty. Tap Customize to add widgets.")
                            .font(StripText.sub).foregroundStyle(p.textTertiary).padding(.horizontal, 12)
                    }
                }
                StripDivider()
                StripIconButton(icon: "slider.horizontal.3", label: "Customize Touch Strip") { customizing = true }
                    .padding(.horizontal, 10)
            }
        }
        .frame(height: 55)
        .background(StripBackground())
    }

    private var edgeTab: some View {
        Button { model.mode = .pinned } label: {
            Image(systemName: "chevron.up")
                .font(AppFont.glyph(10, .semibold))
                .foregroundStyle(p.textSecondary)
                .frame(width: 64, height: 24)
                .background(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).fill(p.isDark ? p.bgBase.opacity(0.85) : p.bgPanel))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8).stroke(p.borderSubtle, lineWidth: 1))
                // Trailing, clear of the centred home indicator; the tap area is finger-sized.
                .padding(.horizontal, 20).padding(.top, 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show Touch Strip")
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 24)
    }
}

/// The panel: translucent (dark) or opaque (light), with a hairline top border.
struct StripBackground: View {
    @Environment(\.theme) private var theme
    var body: some View {
        let p = theme.palette
        ZStack {
            if p.isDark {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(p.bgBase.opacity(0.7))
            } else {
                Rectangle().fill(p.bgPanel)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(p.borderSubtle).frame(height: 1) }
        // Down to the screen edge: the strip sits above the home-indicator area, and
        // the list showed through the gap below it.
        .ignoresSafeArea(edges: .bottom)
    }
}

/// Keys in a row: they stretch to fill the strip when they fit, and scroll
/// sideways when they don't (many widgets on an upright iPad).
struct StripRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { content() }.frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 0) { content() } }
        }
        .frame(maxWidth: .infinity)
    }
}
