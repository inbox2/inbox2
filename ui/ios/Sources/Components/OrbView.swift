import SwiftUI

/// Fraction of the orb canvas occupied by the solid sphere (must match `R` in
/// Orb.metal). The rest of the canvas is the surrounding smoke ring.
private let kOrbSphereFraction: CGFloat = 0.6

/// BMW i electric blue — the orb's friendly accent. Single source in `ChannelColor`.
let kElectricBlue = ChannelColor.electricBlue
/// Brand ring pink — the orb always renders on the dark Bridge surface, so the
/// dark palette is the constant source.
let kPink = ThemePalette.dark.ringColors[1]
// kAqua + the orbit pastels are one-off effect colors, sourced from ChannelColor.
let kAqua = ChannelColor.aqua
// Pastel orbit-track stops (sky -> lilac -> rose) for the swoosh ring below.
private let kOrbitSky = ChannelColor.orbitSky
private let kOrbitLilac = ChannelColor.orbitLilac
private let kOrbitRose = ChannelColor.orbitRose

extension ThemePalette {
    /// The Bridge orb/visualiser hues under Groovebox: its pastel rainbow ring
    /// (coral → mustard → teal → lavender). nil = the electric-blue orb.
    var orbRainbow: [Color]? { guidebookGrid ? ringColors : nil }
    /// Single-hue Bridge accent (glyphs, glow): lavender under Groovebox, else electric blue.
    var bridgeAccent: Color { orbRainbow?.last ?? kElectricBlue }
}

/// The Bridge voice orb — a single-pass Metal sphere (see `Sources/Shaders/Orb.metal`)
/// with white transient smoke wafting *around* it, a centred waveform, an embedded
/// microphone and a gentle breathing pulse. `level` (0…1) swells the waveform from
/// the live mic; nil idles on a soft synthetic breath. Pressing pulls the smoke
/// inward and sinks the orb slightly; releasing calls `action`.
struct OrbView: View {
    @Environment(\.theme) private var theme
    /// Visual diameter of the solid sphere. The drawing canvas is larger to leave
    /// room for the surrounding smoke.
    var size: CGFloat = 210
    /// Live audio level 0…1, or nil to idle.
    var level: Double? = nil
    /// Called when the user starts / stops pressing the orb (push-to-talk).
    var onPressStart: () -> Void = {}
    var onPressEnd: () -> Void = {}

    @State private var start = Date()
    @State private var pressed = false
    @State private var pressChanged = Date()
    // Accumulated waveform phase. We advance it each frame at a rate driven by the
    // live audio `level`, so the pink line oscillates *faster* on loud syllables and
    // slows on pauses — making it read like a robot is talking. Phase is accumulated
    // (rather than `time * freq` in the shader) so changing speed never jumps the wave.
    @State private var wave = WaveClock()

    private var canvas: CGFloat { size / kOrbSphereFraction }

    var body: some View {
        TimelineView(.animation) { ctx in
            let now = ctx.date
            let t = now.timeIntervalSince(start)
            // Idle: a small, slow breath so the line stays nearly calm (just alive,
            // not flowing) until the voice actually drives it.
            let amp = level ?? (0.05 + 0.035 * (sin(t * 0.8) * 0.5 + 0.5))
            let breathe = 1.0 + 0.02 * sin(t * 1.3)
            // Smoothly ramp press 0…1 (fast in, slower out) for the shader + scale.
            let since = now.timeIntervalSince(pressChanged)
            let press = pressed ? min(1.0, since / 0.16) : max(0.0, 1.0 - since / 0.30)

            // Advance the waveform phase (rate driven by `amp`, see `advanceWave`).
            let wavePhase = advanceWave(to: t, amp: amp)

            let p = theme.palette
            let track = p.orbRainbow ?? [kOrbitSky, kOrbitLilac, kOrbitRose]
            let head = p.orbRainbow.map { [$0[0], $0[1]] } ?? [kElectricBlue, kAqua]
            ZStack {
                // Cheap base glow (no shader) so the sphere sits in light.
                RadialGradient(
                    colors: [p.bridgeAccent.opacity(0.24), .clear],
                    center: .center, startRadius: 0, endRadius: canvas * 0.5
                )
                // Sphere + surrounding smoke, one shader pass.
                orb(t: t, amp: amp, press: press, wavePhase: wavePhase)
                // Swoosh: a light app-gradient orbit track (no dark hues) with a
                // bright BMW electric-blue comet head sweeping around it.
                Circle()
                    .stroke(
                        AngularGradient(
                            colors: (track + [track[0]]).map { $0.opacity(0.5) },
                            center: .center
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: size * 1.16, height: size * 1.16)
                Circle()
                    .trim(from: 0.0, to: 0.14)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: head[0].opacity(0.0), location: 0.0),
                                .init(color: head[0], location: 0.11),
                                .init(color: head[1], location: 0.14),
                            ]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .frame(width: size * 1.16, height: size * 1.16)
                    .shadow(color: head[0].opacity(0.9), radius: 6)
                    .rotationEffect(.degrees(t * 75))
            }
            .scaleEffect(breathe * (1.0 - 0.04 * press))
        }
        .frame(width: canvas, height: canvas)
        .contentShape(Circle())
        // Push-to-talk: hold pulls the smoke in + starts listening, release stops.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; pressChanged = Date(); onPressStart() } }
                .onEnded { _ in pressed = false; pressChanged = Date(); onPressEnd() }
        )
        .accessibilityElement()
        .accessibilityLabel("Talk to me")
        .accessibilityAddTraits(.isButton)
    }

    /// Advance and return the accumulated waveform phase. Speed rises steeply with
    /// level (amp²) so the line idles around a calm ~2 rad/s but races toward ~18 rad/s
    /// when the voice is loud — the intonation drives the "talking" oscillation. Phase
    /// is accumulated frame-to-frame so a changing speed never jumps the wave.
    private func advanceWave(to t: TimeInterval, amp: Double) -> Double {
        // Low floor keeps the idle line barely creeping (~0.8 rad/s); the amp² term
        // makes it race toward ~18 rad/s only when the voice gets loud.
        let speed = 0.8 + amp * amp * 17.0
        if wave.last < 0 { wave.last = t }
        let dt = max(0.0, t - wave.last)
        wave.last = t
        wave.phase += dt * speed
        return wave.phase
    }

    private func orb(t: TimeInterval, amp: Double, press: Double, wavePhase: Double) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: canvas, height: canvas)
            .colorEffect(
                ShaderLibrary.magicOrb(
                    .float2(Float(canvas), Float(canvas)),
                    .float(Float(t)),
                    .float(Float(amp)),
                    .float(Float(press)),
                    .float(Float(wavePhase))
                )
            )
    }
}

/// Mutable phase accumulator for the orb waveform. A reference type held in `@State`
/// so the `TimelineView` body can advance it each frame without tripping SwiftUI's
/// "modifying state during view update" guard.
private final class WaveClock {
    var phase: Double = 0
    var last: TimeInterval = -1
}

/// A static, one-frame render of the orb shader placed (invisibly) at launch so the
/// Metal pipeline is compiled before the user first opens the Bridge tab — removes
/// the first-tap hitch without keeping an animation running.
struct OrbWarmup: View {
    var body: some View {
        Rectangle()
            .fill(.white)
            .frame(width: 2, height: 2)
            .colorEffect(
                ShaderLibrary.magicOrb(
                    .float2(Float(2), Float(2)), .float(Float(0)), .float(Float(0)), .float(Float(0)), .float(Float(0))
                )
            )
            .opacity(0.001)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
