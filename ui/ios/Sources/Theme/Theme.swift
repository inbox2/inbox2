import SwiftUI

// Design tokens ported from the desktop app's tokens.css (Vista Aero atmosphere ×
// modern operational SaaS). Dark is the default; light mirrors the desktop light
// theme. Values are translated 1:1 where practical; alpha-over-base surface tokens
// are flattened to opaque approximations for clean SwiftUI compositing.

extension Color {
    init(hex: String, opacity: Double = 1) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255,
            opacity: opacity
        )
    }
    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.init(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }

    /// Light tile behind the dark inbox2 cube logo so it reads on dark surfaces
    /// (the unified channel avatar + `InboxLogoTile`).
    static let unifiedLogoTile = Color(hex: "f2f3f7")
    /// Deeper bottom stop of the logo-tile gradient.
    static let unifiedLogoTileDeep = Color(hex: "e4e6ee")

    /// Always-white Aero edge highlight (the web app's --bevel): sheen gradients,
    /// hairline strokes and glow on raised/colored surfaces. Same in both themes.
    static func bevel(_ opacity: Double) -> Color { .white.opacity(opacity) }
    /// Dimming layer (the web app's --scrim): sheet/drawer backdrops and other
    /// darken-what's-behind fills. Always black, in both themes.
    static func scrim(_ opacity: Double) -> Color { .black.opacity(opacity) }
}

/// The full color set for one theme.
struct ThemePalette {
    // Surfaces
    let bgBase: Color
    let bgPanel: Color
    let bgSurface: Color
    let bgRaised: Color
    let bgElevated: Color
    let bgInput: Color
    /// Steel-navy glow at the very top of a screen backdrop, fading into `bgBase`
    /// (the inbox list page background, per the design reference).
    let bgPageGlow: Color
    // Text
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textMuted: Color
    let textLink: Color
    let textSender: Color
    let textWarm: Color
    // Accents
    let accentPrimary: Color
    let accentWarm: Color
    let accentWarmBright: Color
    let accentSuccess: Color
    let accentWarning: Color
    let accentDanger: Color
    let accentPurple: Color
    let accentAmber: Color
    let accentTeal: Color
    // Borders
    let borderDefault: Color
    let borderSubtle: Color
    let borderStrong: Color
    // Status
    let statusOpen: Color
    let statusPending: Color
    let statusArchived: Color
    let statusSnoozed: Color
    let statusUrgent: Color
    let statusAI: Color
    // Log-level text colors (web --status-*-text) — bright/saturated for the
    // Settings log viewer, darkened in light mode for legibility.
    let statusDangerText: Color
    let statusWarnText: Color
    let statusInfoText: Color
    let statusDebugText: Color
    // Hex strings for the WebView email reader CSS (it needs CSS colors, not Color).
    let webBg: String
    let webText: String
    let webMuted: String
    let webLink: String
    let webQuoteBorder: String
    let webStatusBg: String
    let webStatusText: String
    // Mobile look (per the design reference): a violet primary + a pink→violet→
    // orange ring gradient for channel/avatar circles.
    let accentViolet: Color
    let ringColors: [Color]
    let isDark: Bool
    /// Label colour on a solid `accentViolet` fill. White except on Soirée's gold.
    var onAccent: Color = .white
    /// Fill for floating toasts/bars (`GlowCapsule`) where the default — white on
    /// light, `bgElevated` on dark — lands too close to the page. Atelier/Soirée
    /// need it: their gold hairline can't carry the separation a vivid ring did.
    var floatFill: Color?
    /// Calendar-zone category colours, keyed by the API's palette key (blue/amber/
    /// violet/green/rose/teal). Light themes carry deeper shades so the ~14% fill,
    /// the outline and the mixed label text keep their contrast on a pale page.
    var zoneTones: [String: Color] = ThemePalette.darkZoneTones
    // Groovebox treatments. Every default below is the existing look, so the other
    // themes render unchanged; only `.groovebox` sets them.
    /// Unread dot + unread timestamp ("LED"). nil = `accentViolet`.
    var unreadLED: Color?
    /// Selected/active state (bottom-nav tab, segmented tab, selected day, chosen
    /// option) as a keycap. nil = each control's existing selected look.
    var selectKeycap: Keycap?
    /// Solid primary action (send, sign-in/link, "Add to calendar") as a keycap.
    /// nil = each button's existing flat `accentViolet` fill.
    var primaryKeycap: Keycap?
    /// Secondary buttons as a dark keycap. nil = each button's existing look.
    var secondaryKeycap: Keycap?
    /// Selected rows: solid fill, ringed per `selectionOutline`.
    /// nil = no row fill (the existing check/checkmark carries the state).
    var selectedRowFill: Color?
    /// Ink on a solid pastel fill (tags/chips, calendar event + zone blocks) when
    /// those render solid. nil = the existing dim-fill + coloured-text look.
    var solidChipInk: Color?
    /// Panels (`insetCard`, the inbox list well, settings groups) as solid `bgPanel`
    /// with this corner radius and no glow/bevel. nil = the existing panel look.
    var panelRadius: CGFloat?
    /// Inbox/settings/calendar/bridge page backdrop is the Groovebox guidebook grid.
    var guidebookGrid = false
    /// On-state of toggles. nil = `accentViolet` (so links keep the accent).
    var toggleTint: Color?
    /// Calendar hour-grid lines. nil = each grid's existing line colour.
    var calendarGridLine: Color?
    /// Calendar current-time line. nil = the existing colour.
    var calendarNowLine: Color?

    /// "Rainbow tabs": one colour per bottom-nav slot, in on-screen order (Compose
    /// included). nil = the single-accent bar.
    var navTabColors: [Color]?

    var toggle: Color { toggleTint ?? accentViolet }

    func keycap(_ role: KeycapRole) -> Keycap? {
        switch role {
        case .primary: return primaryKeycap
        case .secondary: return secondaryKeycap
        case .selected: return selectKeycap
        }
    }
    /// Label colour for a button/selection that may be a keycap: the keycap's
    /// label when this theme draws one, else `fallback` (the current look).
    /// The ring around a selection. A light theme's own pale fill stands alone, as on desktop.
    var selectionOutline: Color? { !isDark && selectedRowFill != nil ? nil : accentViolet }

    func keycapLabel(_ role: KeycapRole, or fallback: Color) -> Color { keycap(role)?.label ?? fallback }
    var unread: Color { unreadLED ?? accentViolet }

    /// A zone category's colour; unknown/nil keys fall back to blue.
    func zone(_ key: String?) -> Color { zoneTones[key ?? ""] ?? zoneTones["blue"] ?? .blue }

    static let darkZoneTones: [String: Color] = [
        "blue": Color(hex: "5b8def"), "amber": Color(hex: "d9a441"), "violet": Color(hex: "9a8cc0"),
        "green": Color(hex: "6fb08a"), "rose": Color(hex: "d98a9a"), "teal": Color(hex: "5fb3b3"),
    ]
    static let lightZoneTones: [String: Color] = [
        "blue": Color(hex: "2f64d0"), "amber": Color(hex: "a8701a"), "violet": Color(hex: "6d5aa8"),
        "green": Color(hex: "3d8a5f"), "rose": Color(hex: "b8506a"), "teal": Color(hex: "2a8585"),
    ]

    /// The brand ring as a closed angular sweep — wraps back to the first stop so the
    /// seam is invisible. Single source for AvatarRing + the Bridge orb ring/spinner.
    var ringGradient: AngularGradient {
        AngularGradient(colors: ringColors + [ringColors.first ?? .clear], center: .center)
    }

    static let dark = ThemePalette(
        bgBase: Color(hex: "090a0e"),
        bgPanel: Color(hex: "0d0f15"),
        bgSurface: Color(hex: "15171f"),
        bgRaised: Color(hex: "1b1d25"),
        bgElevated: Color(hex: "1f212b"),
        bgInput: Color(hex: "06070c"),
        bgPageGlow: Color(hex: "1b2334"),
        textPrimary: Color(hex: "e0e0e8"),
        textSecondary: Color(hex: "a0a0b0"),
        textTertiary: Color(hex: "707080"),
        textMuted: Color(hex: "4a4a58"),
        textLink: Color(hex: "a0a8b8"),
        textSender: Color(hex: "e8e8ee"),
        textWarm: Color(hex: "c8a070"),
        accentPrimary: Color(hex: "a0a8b8"),
        accentWarm: Color(r: 27, g: 105, b: 212, a: 0.85),
        accentWarmBright: Color(r: 40, g: 120, b: 230),
        accentSuccess: Color(hex: "7aaa8c"),
        accentWarning: Color(hex: "1B69D4"),
        accentDanger: Color(hex: "c48a88"),
        accentPurple: Color(hex: "a898c0"),
        accentAmber: Color(hex: "d0b468"),
        accentTeal: Color(hex: "78a8a0"),
        borderDefault: Color(r: 255, g: 255, b: 255, a: 0.06),
        borderSubtle: Color(r: 255, g: 255, b: 255, a: 0.03),
        borderStrong: Color(r: 255, g: 255, b: 255, a: 0.10),
        statusOpen: Color(hex: "a0a8b8"),
        statusPending: Color(hex: "c8a060"),
        statusArchived: Color(hex: "585868"),
        statusSnoozed: Color(hex: "a898c0"),
        statusUrgent: Color(hex: "c48a88"),
        statusAI: Color(hex: "78a8a0"),
        statusDangerText: Color(hex: "f87171"),
        statusWarnText: Color(hex: "facc15"),
        statusInfoText: Color(hex: "60a5fa"),
        statusDebugText: Color(hex: "6b7280"),
        webBg: "#0b0d12",
        webText: "#e0e0e8",
        webMuted: "#7b8494",
        webLink: "#5aa0ff",
        webQuoteBorder: "#2a2e38",
        webStatusBg: "#15171f",
        webStatusText: "#9aa3b2",
        accentViolet: Color(hex: "7c5cfc"),
        ringColors: [Color(hex: "a05cff"), Color(hex: "ff5ca8"), Color(hex: "ff9d5c")],
        isDark: true
    )

    static let light = ThemePalette(
        // Light ramp: the desktop's native-macOS ink/accents (tokens.css
        // [data-theme="light"]) over iOS-native grouped surfaces — white cards on
        // systemGroupedBackground, brighter than the Mac's #ececee window grey,
        // which read heavy full-bleed on a phone.
        bgBase: Color(hex: "f2f2f7"),
        bgPanel: Color(hex: "ffffff"),
        bgSurface: Color(hex: "f6f6f8"),
        bgRaised: Color(hex: "ffffff"),
        bgElevated: Color(hex: "ffffff"),
        // White like native iOS text fields on grouped backgrounds — every user
        // pairs it with a borderDefault stroke, which carries the field's edge.
        bgInput: Color(hex: "ffffff"),
        bgPageGlow: Color(hex: "fbfbfd"),
        textPrimary: Color(hex: "1d1d1f"),
        textSecondary: Color(hex: "3c3c43"),
        textTertiary: Color(hex: "6e6e73"),
        textMuted: Color(hex: "8e8e93"),
        textLink: Color(hex: "0069d9"),
        textSender: Color(hex: "000000"),
        textWarm: Color(hex: "b25000"),
        accentPrimary: Color(hex: "0069d9"),
        accentWarm: Color(r: 0, g: 105, b: 217, a: 0.90),
        accentWarmBright: Color(hex: "007aff"),
        accentSuccess: Color(hex: "248a3d"),
        accentWarning: Color(hex: "0069d9"),
        accentDanger: Color(hex: "d70015"),
        accentPurple: Color(hex: "8944ab"),
        accentAmber: Color(hex: "b25000"),
        accentTeal: Color(hex: "0b7f8c"),
        borderDefault: Color(r: 0, g: 0, b: 0, a: 0.11),
        borderSubtle: Color(r: 0, g: 0, b: 0, a: 0.06),
        borderStrong: Color(r: 0, g: 0, b: 0, a: 0.16),
        statusOpen: Color(hex: "0069d9"),
        statusPending: Color(hex: "b25000"),
        statusArchived: Color(hex: "8e8e93"),
        statusSnoozed: Color(hex: "8944ab"),
        statusUrgent: Color(hex: "d70015"),
        statusAI: Color(hex: "0b7f8c"),
        statusDangerText: Color(hex: "c0392b"),
        statusWarnText: Color(hex: "b07a00"),
        statusInfoText: Color(hex: "2563c8"),
        statusDebugText: Color(hex: "6b7280"),
        webBg: "#ffffff",
        webText: "#1d1d1f",
        webMuted: "#6e6e73",
        webLink: "#0069d9",
        webQuoteBorder: "#d5d5da",
        webStatusBg: "#f2f2f7",
        webStatusText: "#6e6e73",
        accentViolet: Color(hex: "0069d9"), // the Mac app's light accent (--accent-primary), beside its --select-fill
        ringColors: [Color(hex: "8a3cf0"), Color(hex: "e0479a"), Color(hex: "f0894c")],
        isDark: false,
        zoneTones: lightZoneTones,
        selectedRowFill: Color(hex: "d3e2f5") // desktop's --select-fill: pale blue, normal dark text
    )

    // Atelier + Soirée — the quiet-luxury pair (web: tokens.css
    // [data-theme-variant="atelier"|"soiree"]). Ivory/cognac/gold by day, bottle
    // green/champagne/gold by night; `accentViolet` carries the theme accent and
    // the ring turns brushed gold. Both switch AppFont to Jost + Bodoni Moda.
    private static let goldRing = [Color(hex: "e7cf98"), Color(hex: "a97f3c"), Color(hex: "f1dfb4"), Color(hex: "b8914a")]

    static let atelier = ThemePalette(
        bgBase: Color(hex: "f5efe6"),
        bgPanel: Color(hex: "fffdf9"),
        bgSurface: Color(hex: "fbf8f3"),
        bgRaised: Color(hex: "fffdf9"),
        bgElevated: Color(hex: "fffdf9"),
        bgInput: Color(hex: "fffdf9"),
        bgPageGlow: Color(hex: "eadfcd"),
        textPrimary: Color(hex: "211b17"),
        textSecondary: Color(hex: "4a3f37"),
        textTertiary: Color(hex: "7a6d60"),
        textMuted: Color(hex: "9a8d80"),
        textLink: Color(hex: "8e4f28"),
        textSender: Color(hex: "1a1511"),
        textWarm: Color(hex: "9a7440"),
        accentPrimary: Color(hex: "8e4f28"),
        accentWarm: Color(r: 142, g: 79, b: 40, a: 0.92),
        accentWarmBright: Color(hex: "9c5a31"),
        accentSuccess: Color(hex: "5e7a52"),
        accentWarning: Color(hex: "8e4f28"),
        accentDanger: Color(hex: "9c3b36"),
        accentPurple: Color(hex: "7b5b78"),
        accentAmber: Color(hex: "9a7440"),
        accentTeal: Color(hex: "4f7a6e"),
        borderDefault: Color(r: 90, g: 60, b: 30, a: 0.14),
        borderSubtle: Color(r: 90, g: 60, b: 30, a: 0.08),
        borderStrong: Color(r: 90, g: 60, b: 30, a: 0.20),
        statusOpen: Color(hex: "8e4f28"),
        statusPending: Color(hex: "9a7440"),
        statusArchived: Color(hex: "9a8d80"),
        statusSnoozed: Color(hex: "7b5b78"),
        statusUrgent: Color(hex: "9c3b36"),
        statusAI: Color(hex: "4f7a6e"),
        statusDangerText: Color(hex: "9c3b36"),
        statusWarnText: Color(hex: "9a6a10"),
        statusInfoText: Color(hex: "4c5f86"),
        statusDebugText: Color(hex: "7a6d60"),
        webBg: "#fffdf9",
        webText: "#211b17",
        webMuted: "#7a6d60",
        webLink: "#8e4f28",
        webQuoteBorder: "#e4d9c8",
        webStatusBg: "#f5efe6",
        webStatusText: "#7a6d60",
        accentViolet: Color(hex: "8e4f28"),
        ringColors: goldRing,
        isDark: false,
        floatFill: Color(hex: "e2d5bf"),
        zoneTones: lightZoneTones
    )

    static let soiree = ThemePalette(
        bgBase: Color(hex: "0b110f"),
        bgPanel: Color(hex: "0e1512"),
        bgSurface: Color(hex: "141e19"),
        bgRaised: Color(hex: "17221d"),
        bgElevated: Color(hex: "1a2620"),
        bgInput: Color(hex: "060a08"),
        bgPageGlow: Color(hex: "17291f"),
        textPrimary: Color(hex: "efe7d7"),
        textSecondary: Color(hex: "b9ae98"),
        textTertiary: Color(hex: "8a8270"),
        textMuted: Color(hex: "5e594c"),
        textLink: Color(hex: "d9bd82"),
        textSender: Color(hex: "f4ede0"),
        textWarm: Color(hex: "d9ba78"),
        accentPrimary: Color(hex: "c9a661"),
        accentWarm: Color(r: 201, g: 166, b: 97, a: 0.85),
        accentWarmBright: Color(hex: "d9ba78"),
        accentSuccess: Color(hex: "7fa88a"),
        accentWarning: Color(hex: "c9a661"),
        accentDanger: Color(hex: "c98b84"),
        accentPurple: Color(hex: "a898c0"),
        accentAmber: Color(hex: "d0b468"),
        accentTeal: Color(hex: "7fa89c"),
        borderDefault: Color(r: 239, g: 231, b: 215, a: 0.07),
        borderSubtle: Color(r: 239, g: 231, b: 215, a: 0.035),
        borderStrong: Color(r: 201, g: 166, b: 97, a: 0.22),
        statusOpen: Color(hex: "c9a661"),
        statusPending: Color(hex: "d0b468"),
        statusArchived: Color(hex: "5e594c"),
        statusSnoozed: Color(hex: "a898c0"),
        statusUrgent: Color(hex: "c98b84"),
        statusAI: Color(hex: "7fa89c"),
        statusDangerText: Color(hex: "f87171"),
        statusWarnText: Color(hex: "facc15"),
        statusInfoText: Color(hex: "93c5fd"),
        statusDebugText: Color(hex: "8a8270"),
        webBg: "#0e1512",
        webText: "#efe7d7",
        webMuted: "#8a8270",
        webLink: "#d9bd82",
        webQuoteBorder: "#26332c",
        webStatusBg: "#141e19",
        webStatusText: "#b9ae98",
        accentViolet: Color(hex: "c9a661"),
        ringColors: goldRing,
        isDark: true,
        onAccent: Color(hex: "1a140c"),
        floatFill: Color(hex: "283a31")
    )

    // Groovebox — a toy synth on a guidebook grid (web: tokens.css
    // [data-theme-variant="groovebox"] + lib/groovebox.js). Near-black island
    // panels over a charcoal violet-gridded ground, one pastel per role: lavender
    // primary, teal success, mustard warning, coral danger, pink tags, LED-green
    // unread. Switches AppFont to Figtree + Rubik.
    static let groovebox = ThemePalette(
        bgBase: Color(hex: "0a0a0b"),
        bgPanel: Color(hex: "121214"),
        bgSurface: Color(hex: "161619"),
        bgRaised: Color(hex: "1b1b1f"),
        bgElevated: Color(hex: "222227"),
        bgInput: Color(hex: "1b1b1f"),
        bgPageGlow: Color(hex: "121214"),
        textPrimary: Color(hex: "f3f0ea"),
        textSecondary: Color(hex: "b4b0b8"),
        textTertiary: Color(hex: "85818c"),
        textMuted: Color(hex: "5d5a63"),
        textLink: Color(hex: "c4b2ff"),
        textSender: Color(hex: "f7f4ee"),
        textWarm: Color(hex: "f0b545"),
        accentPrimary: Color(hex: "a68cf0"),
        accentWarm: Color(r: 166, g: 140, b: 240, a: 0.9),
        accentWarmBright: Color(hex: "c4b2ff"),
        accentSuccess: Color(hex: "44c2b3"),
        accentWarning: Color(hex: "f0b545"),
        accentDanger: Color(hex: "f2785c"),
        accentPurple: Color(hex: "a68cf0"),
        accentAmber: Color(hex: "f0b545"),
        accentTeal: Color(hex: "44c2b3"),
        borderDefault: Color(r: 243, g: 240, b: 234, a: 0.07),
        borderSubtle: Color(r: 243, g: 240, b: 234, a: 0.035),
        borderStrong: Color(r: 243, g: 240, b: 234, a: 0.12),
        statusOpen: Color(hex: "a68cf0"),
        statusPending: Color(hex: "f0b545"),
        statusArchived: Color(hex: "5d5a63"),
        statusSnoozed: Color(hex: "f0a3bd"),
        statusUrgent: Color(hex: "f2785c"),
        statusAI: Color(hex: "44c2b3"),
        statusDangerText: Color(hex: "f2785c"),
        statusWarnText: Color(hex: "f0b545"),
        statusInfoText: Color(hex: "c4b2ff"),
        statusDebugText: Color(hex: "85818c"),
        webBg: "#121214",
        webText: "#f3f0ea",
        webMuted: "#85818c",
        webLink: "#c4b2ff",
        webQuoteBorder: "#2a2a2e",
        webStatusBg: "#1b1b1f",
        webStatusText: "#b4b0b8",
        accentViolet: Color(hex: "a68cf0"),
        ringColors: [Color(hex: "f2785c"), Color(hex: "f0b545"), Color(hex: "44c2b3"), Color(hex: "a68cf0")],
        isDark: true,
        onAccent: Color(hex: "1a1424"),
        zoneTones: [
            "blue": Color(hex: "a68cf0"), "amber": Color(hex: "f0b545"), "violet": Color(hex: "c4b2ff"),
            "green": Color(hex: "5fd68a"), "rose": Color(hex: "f0a3bd"), "teal": Color(hex: "44c2b3"),
        ],
        unreadLED: Color(hex: "5fd68a"),
        selectKeycap: Keycap(fill: [Color(hex: "f6f2e9"), Color(hex: "e4ded1")], edge: Color(hex: "a9a192"),
                             edgeHeight: 3, highlight: 1, label: Color(hex: "1c1b1f")),
        primaryKeycap: Keycap(fill: [Color(hex: "d9ccff"), Color(hex: "a68cf0"), Color(hex: "8466e0")],
                              edge: Color(hex: "5a40a8"), edgeHeight: 2, highlight: 0.45,
                              label: Color(hex: "1a1424"), dome: true),
        secondaryKeycap: Keycap(fill: [Color(hex: "34343a"), Color(hex: "26262b")], edge: Color(hex: "08080a"),
                                label: Color(hex: "f3f0ea")),
        selectedRowFill: Color(hex: "262233"),
        solidChipInk: Color(hex: "141416"),
        panelRadius: 20,
        guidebookGrid: true,
        toggleTint: Color(hex: "44c2b3"),
        calendarGridLine: Color(r: 148, g: 121, b: 216, a: 0.25),
        calendarNowLine: Color(hex: "f0b545"),
        // Inbox · Explorer · Compose · Calendar · Settings.
        navTabColors: [Color(hex: "f2785c"), Color(hex: "f0b545"), Color(hex: "44c2b3"),
                       Color(hex: "a68cf0"), Color(hex: "f0a3bd")]
    )
}

/// A toy-synth keycap (Groovebox): a top-lit fill sitting on a hard, darker bottom
/// edge, with a light hairline along its top. `dome` swaps the vertical gradient
/// for the primary button's radial "dome" (lit from the upper left).
struct Keycap {
    let fill: [Color]
    let edge: Color
    var edgeHeight: CGFloat = 2
    /// White opacity of the 1pt top highlight.
    var highlight: Double = 0.09
    let label: Color
    var dome = false
}

enum KeycapRole { case primary, secondary, selected }

/// A surface that is a keycap under themes that define one for `role` (Groovebox)
/// and `fallback` — the control's existing background — everywhere else.
private struct KeycapSurface<Fallback: View>: ViewModifier {
    @Environment(\.theme) private var theme
    let role: KeycapRole
    let radius: CGFloat
    let fallback: Fallback

    func body(content: Content) -> some View {
        if let k = theme.palette.keycap(role) {
            content.background { Color.clear.keycap(k, radius: radius) }
        } else {
            content.background { fallback }
        }
    }
}

extension View {
    /// The reusable Groovebox button/selection surface: a `role` keycap under
    /// themes that define one, else `fallback` (default: nothing — a no-op).
    /// Labels should take `palette.keycapLabel(role, or:)` for their colour.
    func keycapSurface<B: View>(_ role: KeycapRole, radius: CGFloat,
                                @ViewBuilder fallback: () -> B = { EmptyView() }) -> some View {
        modifier(KeycapSurface(role: role, radius: radius, fallback: fallback()))
    }

    /// Paint a `Keycap` behind this view, clipped to a rounded rect of `radius`
    /// (pass `Radius.full` for a capsule). The edge peeks out below the cap, outside
    /// the view's frame, so layout is unchanged.
    func keycap(_ k: Keycap, radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let fill: AnyShapeStyle = k.dome
            ? AnyShapeStyle(RadialGradient(colors: k.fill, center: UnitPoint(x: 0.38, y: 0.28),
                                           startRadius: 0, endRadius: 90))
            : AnyShapeStyle(LinearGradient(colors: k.fill, startPoint: .top, endPoint: .bottom))
        return foregroundStyle(k.label)
            .background {
                ZStack {
                    shape.fill(k.edge).offset(y: k.edgeHeight)
                    shape.fill(fill)
                    // 1pt top highlight: a hairline that fades out down the sides.
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.bevel(k.highlight), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                }
            }
    }
}

/// Type scale (px → pt) from tokens.css, on the SF Pro system font — or a theme's
/// own pair: Jost + Bodoni Moda under Atelier/Soirée, Figtree + Rubik under
/// Groovebox (all SIL OFL variable TTFs, registered via UIAppFonts).
enum AppFont {
    /// A theme's UI face + title-tier face (and the weight the title tier uses).
    struct Faces {
        let ui: String
        let display: String
        let displayWeight: Font.Weight
        /// Section headers (settings/calendar group labels) also take the display face.
        var displaySections = false
        static let luxe = Faces(ui: "Jost", display: "Bodoni Moda", displayWeight: .medium)
        static let groovebox = Faces(ui: "Figtree", display: "Rubik", displayWeight: .bold, displaySections: true)
    }
    /// The live theme face set (nil = SF Pro). Flipped by ThemeManager when the
    /// appearance changes; read whenever a view builds its body. Main-thread only in practice.
    /// ponytail: a global, not an environment value — views that don't read `theme`
    /// pick a switched face up on their next render, not instantly.
    nonisolated(unsafe) static var faces: Faces?

    /// Raw size factory — for off-scale glyph/icon sizes and avatar initials only.
    /// Text takes a named step (`sm`, `xs2(.semibold)` …) so the scale stays the scale.
    static func glyph(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        faces.map { .custom($0.ui, size: size).weight(weight) } ?? .system(size: size, weight: weight)
    }
    /// Small section-header label: the display face where the theme opts in
    /// (Groovebox: Rubik), else `glyph(size, weight)`.
    static func section(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        if let f = faces, f.displaySections { return .custom(f.display, size: size).weight(weight) }
        return glyph(size, weight)
    }
    /// Title tier: the theme's display face, else `ui`.
    private static func heading(_ size: CGFloat) -> Font {
        faces.map { .custom($0.display, size: size).weight($0.displayWeight) } ?? glyph(size, .semibold)
    }
    // Title / header tier — above the body scale, weight baked at the common header
    // weight. Chain `.smallCaps()` at the call site for the brand uppercase headers.
    /// Display size — onboarding/empty-state hero text + large feature glyphs.
    static var display: Font { heading(26) }
    static var title: Font { heading(22) }        // screen + section titles
    static var title2: Font { glyph(19, .semibold) } // sub-headers, prominent nav/bulk icons
    static var title3: Font { glyph(17, .semibold) } // row headers (month/folder), back chevron
    static var xl: Font { heading(20) }
    static var lg: Font { glyph(18, .semibold) }
    /// iOS default body size (17pt, regular) — settings rows + list detail text.
    static var body: Font { glyph(17) }
    static var md: Font { glyph(16, .medium) }
    static var base: Font { glyph(15) }
    static var sm: Font { glyph(14) }
    static var xs: Font { glyph(13) }
    static var xs2: Font { glyph(12) }
    static var xs3: Font { glyph(11, .medium) }
    // Weight variants of the named steps — the same size at a non-default weight
    // (`AppFont.sm(.semibold)`), so a feature view never reaches for a raw size.
    static func lg(_ w: Font.Weight) -> Font { glyph(18, w) }
    static func body(_ w: Font.Weight) -> Font { glyph(17, w) }
    static func md(_ w: Font.Weight) -> Font { glyph(16, w) }
    static func base(_ w: Font.Weight) -> Font { glyph(15, w) }
    static func sm(_ w: Font.Weight) -> Font { glyph(14, w) }
    static func xs(_ w: Font.Weight) -> Font { glyph(13, w) }
    static func xs2(_ w: Font.Weight) -> Font { glyph(12, w) }
    static func xs3(_ w: Font.Weight) -> Font { glyph(11, w) }
    /// SF Mono (the system monospaced design) — the single token for all code /
    /// monospace text (`<tldr />`, IDs, headers, debug values).
    static func mono(_ size: CGFloat = 12, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    /// Brand display font for hero/screen titles: the system face in its expanded
    /// width. Was PP Monument Extended, a commercial font that can't ship in the
    /// public repo (2026-11-19). `black: true` selects the Black weight.
    static func monument(_ size: CGFloat, black: Bool = false) -> Font {
        .system(size: size, weight: black ? .black : .regular).width(.expanded)
    }
}

/// Spacing (4px grid) + radii from tokens.css.
enum Space {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
}

enum Radius {
    static let xs: CGFloat = 2
    static let sm: CGFloat = 3
    static let md: CGFloat = 5
    static let lg: CGFloat = 8
    static let xl: CGFloat = 12
    static let full: CGFloat = 9999
}

/// The active theme, injected via the environment.
struct Theme {
    let palette: ThemePalette
    static let dark = Theme(palette: .dark)
    static let light = Theme(palette: .light)
    static let atelier = Theme(palette: .atelier)
    static let soiree = Theme(palette: .soiree)
    static let groovebox = Theme(palette: .groovebox)
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
