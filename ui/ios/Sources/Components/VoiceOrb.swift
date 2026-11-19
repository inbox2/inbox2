import SwiftUI

/// A wobbling metaball outline — a circle perturbed by a few sine harmonics so it reads
/// as a soft, living blob rather than a rigid disc. `phase` advances with time and
/// `wobble` scales the distortion (louder voice → more restless), so the body, its glow
/// and rim, and the voice-wave rings can all share one shape and stay aligned.
struct BlobShape: Shape {
    var phase: Double
    var wobble: Double
    var lobes: Double = 3

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let base = min(rect.width, rect.height) / 2
        var path = Path()
        let steps = 96
        for i in 0...steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let d = 0.055 * sin(lobes * a + phase)
                  + 0.040 * sin((lobes + 2) * a - phase * 1.27)
                  + 0.028 * sin(2 * a + phase * 0.6)
            let r = base * (1 + wobble * d)
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// A neon, blobby, "fleshy" voice orb — the read-aloud indicator. A soft gradient
/// metaball that breathes with a double-thump heartbeat while thinking (`level == nil`)
/// and swells, brightens, and throws off voice-wave ripples with the live speech
/// amplitude. Replaces the old milky-white indicator: deliberately neon (the app ring
/// palette — electric-blue → violet → pink → amber) and organic, and distinct from the
/// Bridge's electric `OrbView` (untouched).
struct VoiceOrb: View {
    /// Diameter of the blob (the glow/ripples bloom beyond it).
    var size: CGFloat = 28
    /// Live speech amplitude 0…1, or `nil` to idle (heartbeat).
    var level: Double? = nil
    /// Mid-stream buffering (the Kokoro stream ran dry while the next chunk
    /// synthesizes): the blob calms and dims, and a neon arc orbits it as a spinner.
    /// Playback resuming flips this back and the glow orb returns.
    var spinning: Bool = false
    /// Neon gradient stops; defaults to the app ring palette when omitted.
    var colors: [Color]? = nil

    @Environment(\.theme) private var theme
    @State private var start = Date()

    private var palette: [Color] {
        if let colors, !colors.isEmpty { return colors }
        return theme.palette.ringColors
    }
    /// Closed loop so the angular gradient has no hard seam.
    private var ring: [Color] { palette + [palette.first ?? .blue] }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            let amp = spinning ? 0 : max(0, min(1, level ?? 0))
            let idle = level == nil && !spinning
            let beat = idle ? heartbeat(t) : 0
            // Outline restlessness: a calm idle wobble, much busier under the voice;
            // nearly still while buffering so the spinner reads as "waiting".
            let wobble = spinning ? 0.22 : 0.5 + beat * 0.5 + amp * 1.5
            let phase = t * 1.6
            let swell = spinning ? 0.9 : 1.0 + beat * 0.08 + amp * 0.22
            let glow = spinning ? 0.22 : 0.40 + (idle ? 0.16 * beat : amp * 0.6)

            ZStack {
                if !spinning {
                    ripples(t: t, amp: amp, idle: idle, beat: beat)
                }
                glowLayer(phase: phase, wobble: wobble, glow: glow)
                bodyLayer(t: t, amp: amp, phase: phase, wobble: wobble, glow: glow)
                if spinning {
                    spinnerArc(t: t)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(swell)
            .animation(.easeInOut(duration: 0.25), value: spinning)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Outer neon glow — a blurred, oversized copy of the blob.
    private func glowLayer(phase: Double, wobble: Double, glow: Double) -> some View {
        BlobShape(phase: phase, wobble: wobble)
            .fill(AngularGradient(colors: ring, center: .center))
            .frame(width: size * 1.5, height: size * 1.5)
            .blur(radius: size * 0.28)
            .opacity(0.30 + glow * 0.55)
    }

    /// The body: a slowly rotating neon angular gradient, brightened toward the top-left
    /// like a lit sphere, with drifting inner "cells" so it feels fleshy and alive — all
    /// clipped to the wobbling blob, with a glassy rim, a specular glint, and a neon cast
    /// shadow.
    private func bodyLayer(t: Double, amp: Double, phase: Double, wobble: Double, glow: Double) -> some View {
        let core = Color.bevel(0.50 + amp * 0.4)
        let rim = LinearGradient(colors: [.bevel(0.85), .bevel(0.10)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)
        return ZStack {
            AngularGradient(colors: ring, center: .center, angle: .degrees(t * 30))
            RadialGradient(colors: [core, .clear],
                           center: UnitPoint(x: 0.34, y: 0.30),
                           startRadius: 0, endRadius: size * 0.6)
            innerCells(t: t)
        }
        .frame(width: size, height: size)
        .clipShape(BlobShape(phase: phase, wobble: wobble))
        .overlay(BlobShape(phase: phase, wobble: wobble)
            .stroke(rim, lineWidth: max(0.6, size * 0.025)))
        .overlay(specular)
        .shadow(color: (palette.first ?? .blue).opacity(glow * 0.7), radius: size * 0.22)
    }

    /// Drifting translucent neon cells inside the body → the living, fleshy interior.
    private func innerCells(t: Double) -> some View {
        ForEach(0..<3, id: \.self) { i in
            let p = Double(i)
            let dx = CGFloat(sin(t * 0.9 + p * 2.2)) * size * 0.16
            let dy = CGFloat(cos(t * 0.7 + p * 1.6)) * size * 0.16
            Circle()
                .fill(palette[(i + 1) % palette.count].opacity(0.55))
                .frame(width: size * 0.5, height: size * 0.5)
                .blur(radius: size * 0.18)
                .offset(x: dx, y: dy)
        }
    }

    /// The buffering spinner: a neon gradient arc orbiting the calmed blob.
    private func spinnerArc(t: Double) -> some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(AngularGradient(colors: ring, center: .center),
                    style: StrokeStyle(lineWidth: max(1.5, size * 0.045), lineCap: .round))
            .frame(width: size * 1.3, height: size * 1.3)
            .rotationEffect(.degrees(t * 300))
            .shadow(color: (palette.first ?? .blue).opacity(0.6), radius: size * 0.08)
    }

    /// A small soft top-left highlight — the lit-glass glint.
    private var specular: some View {
        Ellipse()
            .fill(Color.bevel(0.7))
            .frame(width: size * 0.22, height: size * 0.16)
            .blur(radius: size * 0.06)
            .offset(x: -size * 0.16, y: -size * 0.18)
    }

    /// Concentric voice-wave rings that bloom outward and fade — a faint pulse on the
    /// idle heartbeat, surging with the speech amplitude.
    private func ripples(t: Double, amp: Double, idle: Bool, beat: Double) -> some View {
        let intensity = idle ? beat * 0.45 : (0.3 + amp)
        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                let cycle = (t * 0.6 + Double(i) / 3.0).truncatingRemainder(dividingBy: 1)
                let scale = 1.0 + cycle * 1.1
                let fade = (1 - cycle) * intensity
                BlobShape(phase: t * 1.2 + Double(i), wobble: 0.6)
                    .stroke(palette[i % palette.count].opacity(fade * 0.7),
                            lineWidth: max(0.8, size * 0.03))
                    .frame(width: size, height: size)
                    .scaleEffect(scale)
            }
        }
    }

    /// A double-thump heartbeat curve over a ~1.15s period → 0…1.
    private func heartbeat(_ t: Double) -> Double {
        let period = 1.15
        let x = t.truncatingRemainder(dividingBy: period) / period
        let a = exp(-pow((x - 0.10) / 0.05, 2))
        let b = 0.55 * exp(-pow((x - 0.26) / 0.05, 2))
        return min(1, a + b)
    }
}

/// The persistent, app-wide read-aloud indicator — the standard shared orb. Drawn at the
/// root (above every nav bar) so it can overflow freely. While the shared `Speaker` is
/// talking (or preparing to), a tappable neon `VoiceOrb` appears — tap to stop, touch-hold
/// and drag to move it anywhere (the spot is remembered, stored as screen fractions so it
/// survives rotation). It blooms in and contracts into itself when speech ends. Suppressed
/// only on the Bridge, which shows its own `OrbView`.
struct FloatingVoiceOrb: View {
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var presence: VoicePresence
    @EnvironmentObject private var readAloud: ReadAloudController
    @ObservedObject private var levels = AudioLevels.shared

    /// Last user-chosen spot as fractions of the overlay size (default: centered, ~27% down).
    @AppStorage("voiceOrbFractionX") private var fractionX = 0.5
    @AppStorage("voiceOrbFractionY") private var fractionY = 0.27
    @State private var dragOffset: CGSize = .zero
    @State private var dragging = false

    /// Speaking or about to (covers the fetch/load gap before audio starts).
    private var active: Bool { speaker.isSpeaking || speaker.isPreparing }
    private var shouldShow: Bool { active && !presence.bridgeVisible }

    var body: some View {
        GeometryReader { geo in
            let lvl: Double? = speaker.isSpeaking ? levels.speaker : nil
            let home = clamped(CGPoint(x: geo.size.width * fractionX,
                                       y: geo.size.height * fractionY), in: geo.size)
            let shown = clamped(CGPoint(x: home.x + dragOffset.width,
                                        y: home.y + dragOffset.height), in: geo.size)
            ZStack {
                if shouldShow {
                    VoiceOrb(size: 88, level: lvl, spinning: speaker.isBuffering)
                        .contentShape(Circle())
                        .scaleEffect(dragging ? 1.12 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragging)
                        // Stop the read-aloud session (not just the speech) so a tap here
                        // fully ends it rather than tripping the "speech ended" triage window.
                        .onTapGesture { readAloud.stop(); speaker.stop() }
                        .gesture(holdDrag(home: home, in: geo.size))
                        .position(shown)
                        .transition(.scale(scale: 0.05).combined(with: .opacity))
                        .accessibilityLabel("Stop reading aloud")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Touch and hold, then drag to move")
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Inert whenever the orb isn't shown, so this full-screen overlay can never
            // intercept taps meant for the chrome beneath it (e.g. a reader's back button).
            .allowsHitTesting(shouldShow)
            .animation(.spring(response: 0.5, dampingFraction: 0.68), value: shouldShow)
        }
        // When speech ends anywhere, drop the "which conversation is reading" marker so a
        // later reopen of that thread doesn't falsely resume the playing state.
        .onChange(of: active) { _, isActive in
            if !isActive { presence.readingConversationId = nil }
        }
    }

    /// Touch-hold then drag to relocate the orb; a quick tap still falls through to the
    /// stop action. The end position is persisted as screen fractions.
    /// The drag is measured in the global space — the local space moves with the orb,
    /// so a locally-measured translation perpetually trails the finger.
    private func holdDrag(home: CGPoint, in size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !dragging {
                    dragging = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                dragOffset = drag?.translation ?? .zero
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    let end = clamped(CGPoint(x: home.x + drag.translation.width,
                                              y: home.y + drag.translation.height), in: size)
                    fractionX = end.x / max(size.width, 1)
                    fractionY = end.y / max(size.height, 1)
                }
                dragging = false
                dragOffset = .zero
            }
    }

    /// Keep the orb's center far enough from every edge that the blob (and its glow)
    /// stays reachable on screen.
    private func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let margin: CGFloat = 56
        return CGPoint(x: min(max(point.x, margin), max(size.width - margin, margin)),
                       y: min(max(point.y, margin), max(size.height - margin, margin)))
    }
}

/// A compact live audio graph — a row of neon bars that dance with the speech `level`.
/// Shown in the reader's toolbar while reading aloud (the speaker icon "comes alive"),
/// alongside the centered shared orb.
struct VoiceBars: View {
    @Environment(\.theme) private var theme
    var level: Double
    var barCount: Int = 4

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(LinearGradient(colors: theme.palette.ringColors,
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: barHeight(i, t))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let phase = Double(i) * 0.8
        let wobble = sin(t * 7 + phase) * 0.5 + 0.5            // 0…1
        let h = 4 + level * 18 * (0.35 + 0.65 * wobble)
        return max(4, CGFloat(h))
    }
}
