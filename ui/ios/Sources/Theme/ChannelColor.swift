import SwiftUI

/// Deterministic per-channel colors. Keyed by the account key so a given mailbox
/// always renders the same hue wherever it appears — the agenda event strip, the
/// month-grid dots, and the 7-day load chart all line up. The palette opens on a
/// BMW-style electric blue and fans out across distinct hues; each entry is a
/// gradient (lighter top → deeper bottom) so it reads on the dark surfaces and
/// keeps the Vista-Aero beveled feel rather than a flat fill.
enum ChannelColor {
    // Canonical brand hues — single source of truth. The gradient table below is
    // built from these, and chrome/orb accents that must match a channel hue
    // (FloatingNavBar's Bridge blue, GlowCapsule's inbox violet, OrbView) reference
    // them directly rather than re-typing the hexes.
    static let electricBlue = Color(hex: "4DA6FF")      // BMW i hero
    static let electricBlueDeep = Color(hex: "0A63E6")
    static let violet = Color(hex: "A78BFF")
    static let violetDeep = Color(hex: "6A3FE0")
    static let amber = Color(hex: "FFB35C")             // also the triage toast accent
    static let amberDeep = Color(hex: "F0822E")
    static let coral = Color(hex: "FF7A6B")             // also the destructive toast accent
    static let coralDeep = Color(hex: "E0463F")
    // Bridge orb one-off effect hues (OrbView): the aqua waveform + the pastel
    // orbit-track stops (sky → lilac → rose). Not channel hues; kept here so no
    // view hardcodes a Color(hex:).
    static let aqua = Color(hex: "8DECFF")
    static let orbitSky = Color(hex: "9BD0FF")
    static let orbitLilac = Color(hex: "C7B3FF")
    static let orbitRose = Color(hex: "FF9DC8")
    /// Settings-tab steel accent (MobileChrome's NavStyle) — mirrors Android's
    /// ChannelColor.steel.
    static let steel = [Color(hex: "EAEEF4"), Color(hex: "9AA2AE")]

    /// Gradient stops (top → bottom). The first entry is the electric blue; the
    /// rest walk the wheel so neighbouring channels stay easy to tell apart.
    static let gradients: [[Color]] = [
        [electricBlue, electricBlueDeep],             // electric blue (BMW i)
        [Color(hex: "32E0C4"), Color(hex: "0FA48C")], // teal
        [violet, violetDeep],                         // violet
        [Color(hex: "FF74B8"), Color(hex: "E03F92")], // magenta
        [amber, amberDeep],                           // amber
        [Color(hex: "5FD98A"), Color(hex: "2FA85E")], // emerald
        [coral, coralDeep],                           // coral
        [Color(hex: "6E8BFF"), Color(hex: "3F52E0")], // indigo
    ]

    /// Palette index for a channel. When `order` (the user's connected-account list,
    /// same order as the channel switcher) contains the key we map by position — so
    /// the first channel is the electric blue and the rest fan out in switcher order.
    /// Unknown keys fall back to a stable FNV-1a hash so they still get a fixed hue.
    static func index(for key: String, in order: [String] = []) -> Int {
        if let i = order.firstIndex(of: key) { return i % gradients.count }
        guard !key.isEmpty else { return 0 }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return Int(h % UInt64(gradients.count))
    }

    static func stops(for key: String, in order: [String] = []) -> [Color] {
        gradients[index(for: key, in: order)]
    }

    /// Top → bottom gradient for bars and the event accent strip.
    static func gradient(for key: String, in order: [String] = []) -> LinearGradient {
        LinearGradient(colors: stops(for: key, in: order), startPoint: .top, endPoint: .bottom)
    }

    /// Single representative colour (the lighter top stop) for dots and small marks
    /// where a gradient wouldn't be visible.
    static func base(for key: String, in order: [String] = []) -> Color {
        stops(for: key, in: order).first ?? .accentColor
    }
}
