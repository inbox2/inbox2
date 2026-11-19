import SwiftUI
import UIKit

/// User appearance preference. Dark is the default (the product prefers dark).
enum Appearance: String, CaseIterable, Identifiable {
    case system, dark, light, soiree, atelier, groovebox
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        case .soiree: return "Soirée"
        case .atelier: return "Atelier"
        case .groovebox: return "Groovebox"
        }
    }
    /// The theme's own UI + display faces (AppFont.faces); nil = SF Pro.
    var fontFaces: AppFont.Faces? {
        switch self {
        case .soiree, .atelier: return .luxe
        case .groovebox: return .groovebox
        default: return nil
        }
    }
    /// The system colour scheme this appearance pins (nil = follow the system).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark, .soiree, .groovebox: return .dark
        case .light, .atelier: return .light
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    private static let key = "inbox2_appearance"

    @Published var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.key)
            AppFont.faces = appearance.fontFaces
            syncWindowOverride()
        }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.key)
        appearance = raw.flatMap(Appearance.init(rawValue:)) ?? .dark
        AppFont.faces = appearance.fontFaces
    }

    /// Pin the appearance at the UIWindow level. `.preferredColorScheme` alone
    /// is a SwiftUI-side override that does NOT hold while iOS renders the
    /// app-switcher snapshots on backgrounding (the system flips the window's
    /// interface-style traits to capture both appearances) — so a dark-pinned
    /// app got a light snapshot card in the switcher. A window-level
    /// `overrideUserInterfaceStyle` is honored by those snapshot passes.
    /// Call whenever the appearance changes and when a scene becomes active
    /// (windows don't exist yet at app init).
    func syncWindowOverride() {
        let style: UIUserInterfaceStyle
        switch appearance.colorScheme {
        case nil: style = .unspecified
        case .dark: style = .dark
        default: style = .light
        }
        for window in Self.appWindows { window.overrideUserInterfaceStyle = style }
    }

    /// Freeze the *resolved* appearance onto the windows while the app leaves the
    /// foreground. With `.system` the override stays `.unspecified`, so the
    /// alternate-style switcher-snapshot pass flips the window traits, ThemedRoot
    /// re-resolves the token theme, and iOS stores a light snapshot the switcher
    /// can show even on a dark device. Pinning the current trait makes both
    /// snapshot variants render the appearance the user last saw; `.active`
    /// re-runs `syncWindowOverride()`, which unfreezes `.system` back to
    /// `.unspecified`. For pinned dark/light this is a no-op.
    func freezeWindowStyle() {
        for window in Self.appWindows {
            window.overrideUserInterfaceStyle = window.traitCollection.userInterfaceStyle
        }
    }

    private static var appWindows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    /// Drives `.preferredColorScheme`; nil = follow the system.
    var preferredColorScheme: ColorScheme? { appearance.colorScheme }

    /// Resolve the token set, falling back to the system scheme when `.system`.
    func theme(systemScheme: ColorScheme) -> Theme {
        switch appearance {
        case .dark: return .dark
        case .light: return .light
        case .soiree: return .soiree
        case .atelier: return .atelier
        case .groovebox: return .groovebox
        case .system: return systemScheme == .dark ? .dark : .light
        }
    }
}
