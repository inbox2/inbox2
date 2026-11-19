import GameController
import SwiftUI

/// Modifier keys held on a hardware keyboard right now (iPad Magic Keyboard, any
/// Bluetooth keyboard). SwiftUI's `onModifierKeysChanged` is macOS-only, and a tap
/// carries no modifiers, so the keyboard itself is asked at the moment of the tap.
enum HeldKeys {
    /// The framework finds a keyboard asynchronously: start it at launch, not on the first tap.
    @MainActor static func start() { HeldModifiers.shared.start() }

    static var current: EventModifiers {
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return [] }
        let down = { (codes: [GCKeyCode]) in codes.contains { keys.button(forKeyCode: $0)?.isPressed == true } }
        var held: EventModifiers = []
        if down([.leftShift, .rightShift]) { held.insert(.shift) }
        if down([.leftGUI, .rightGUI]) { held.insert(.command) }
        return held
    }
}

/// Whether Shift or Command is down, as state a view can watch. A conversation row's
/// text column is a `Menu`, and a Shift- or Command-click on a menu button never
/// reaches its `primaryAction`, so the row drops the menu while a selecting key is held.
@MainActor
final class HeldModifiers: ObservableObject {
    static let shared = HeldModifiers()
    @Published private(set) var selecting = false

    func start() {
        attach()
        let center = NotificationCenter.default
        center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.attach(); self.resync() }
        }
        // A keyboard that goes away with a key down never reports the key-up either.
        center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.attach(); self.resync() }
        }
        // A key released while another app has focus never reports its key-up.
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.set(false) }
        }
    }

    private func attach() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { _, _, _, _ in
            MainActor.assumeIsolated { self.resync() }
        }
    }

    /// With no keyboard left, `HeldKeys.current` is empty, so this clears the state.
    private func resync() { set(!HeldKeys.current.isDisjoint(with: [.shift, .command])) }

    /// Only a real change publishes: every keystroke lands here.
    private func set(_ on: Bool) { if selecting != on { selecting = on } }
}
