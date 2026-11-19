import AVFoundation
import SwiftUI

/// The Bridge — the eyes-free team cockpit (lives in the "Explorer" tab slot). A
/// "Hey, press me" button speaks the team SITREP; holding the orb (push-to-talk)
/// listens — the caption swaps to live pink audio bars + transcript, and the orb's
/// waveform tracks your voice. On release the transcript goes to the agent brain
/// and the reply is spoken.
struct BridgeView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var voice: VoiceEngineManager
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var router: BridgeRouter
    @ObservedObject private var levels = AudioLevels.shared
    @StateObject private var listening = ListeningManager()
    /// Briefs, the command → intent dispatch, barge-in, mic access and the status line.
    @StateObject private var session = BridgeSession()
    @State private var showGame = false
    /// A randomly chosen, attention-grabbing label for the prompt button (re-picked
    /// each time the Bridge appears).
    @State private var promptLabel = BridgePrompts.random()

    /// Drives the orb waveform: the live mic while listening, the agent's speech
    /// while it talks back, otherwise nil (idle breath).
    private var orbLevel: Double? {
        if listening.isListening { return listening.level }
        if speaker.isSpeaking { return levels.speaker }
        return nil
    }

    /// The TTS lane that will actually run, for the status line.
    private var ttsLane: String {
        engine.effectiveLane("tts", pref: voice.ttsPref, hasKey: voice.canUseOpenAI)
    }

    /// A short description of what the Bridge engine is doing right now, or nil when
    /// idle. Shown small under the prompt button.
    private var engineStatus: String? {
        if session.engineLoading { return "Getting ready…" }
        if let s = session.transientStatus { return s }
        if session.isGenerating { return "Composing your brief…" }
        if speaker.isPreparing {
            switch ttsLane {
            case "openai": return "Loading OpenAI voice…"
            case "free": return "Loading \(KokoroVoice.named(voice.kokoroVoiceId).name)…"
            default: return "Preparing…"
            }
        }
        if speaker.isSpeaking {
            switch ttsLane {
            case "openai": return "Speaking · OpenAI"
            case "free": return "Speaking · \(KokoroVoice.named(voice.kokoroVoiceId).name)"
            case "native": return "Speaking · on-device"
            default: return "Speaking…"
            }
        }
        return nil
    }



    /// True while the background worker is still catching up on the in-window backlog.
    private var triageActive: Bool { engine.triage.isActive && engine.triage.inWindow > 0 }

    /// The date the worker is currently at (newest-first), shown beside the label.
    private var triageDateLabel: String? {
        engine.triage.currentDate?.formatted(.dateTime.month(.abbreviated).day().year())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Centered screen title — brand display font (no small-caps feature in
            // Monument Extended, so uppercase the text instead).
            Text("Bridge")
                .textCase(.uppercase)
                .font(AppFont.monument(18))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)

            Spacer()

            // Press → generate (gradient loading spinner) → speak the SITREP (orb
            // waveform tracks it). Press again while speaking → stop mid-sentence.
            VStack(spacing: Space.s2) {
                TldrButton(label: promptLabel,
                           isGenerating: session.isGenerating || speaker.isPreparing || session.engineLoading,
                           isSpeaking: speaker.isSpeaking) {
                    if speaker.isSpeaking {
                        speaker.stop()
                    } else {
                        session.speakBrief()
                    }
                }
                // Small live status — what the engine is doing right now (composing the
                // brief, loading the voice, or speaking, and on which lane).
                Text(engineStatus ?? " ")
                    .font(AppFont.xs2)
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(minHeight: 15)
                    .modifier(StatusCapsule(visible: engineStatus != nil))
                    .animation(.easeInOut(duration: 0.2), value: engineStatus)

                // Follow-ups: tomorrow's preview and the weekly highlights, shown
                // together at equal width. Tapping one interrupts the other; both are
                // inert while a brief is being prepared so a double-tap can't stack two.
                // When hidden (before the first brief, or after they fade), a tap in the
                // same spot summons them on demand.
                Group {
                    if triageActive {
                        // While catching up, this slot stays empty so the area under the
                        // button is uncluttered — the progress renders centered in the gap
                        // between the status line and the orb instead (see below).
                        Color.clear.frame(height: 0)
                    } else if session.showFollowUps {
                        HStack(spacing: Space.s3) {
                            BridgeQuickLink(icon: "sun.max.fill", label: "Check tomorrow", fillWidth: true, action: session.speakTomorrow)
                            BridgeQuickLink(icon: "calendar", label: "Weekly highlights", fillWidth: true, action: session.speakWeek)
                        }
                        .padding(.horizontal, Space.s6)
                        .disabled(session.isBusy)
                        .opacity(session.isBusy ? 0.5 : 1)
                        .transition(.opacity)
                    } else {
                        Button(action: session.revealFollowUps) {
                            HStack(spacing: Space.s1 + 1) {
                                Image(systemName: "ellipsis")
                                    .font(AppFont.xs2(.semibold))
                                Text("Tomorrow & weekly highlights")
                                    .font(AppFont.xs2(.medium))
                            }
                            .foregroundStyle(theme.palette.panelRadius != nil ? theme.palette.textSecondary : theme.palette.textMuted)
                            .padding(.vertical, Space.s1 + 2)
                            .grooveCapsule()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableLinkStyle())
                        .transition(.opacity)
                    }
                }
                .padding(.top, Space.s1)
                .animation(.easeInOut(duration: 0.25), value: session.showFollowUps)
                .animation(.easeInOut(duration: 0.2), value: session.isBusy)
                .animation(.easeInOut(duration: 0.25), value: engine.triage.isActive)
            }

            // Catch-up progress is vertically centered in the space between the status
            // line and the orb; the gap keeps its height when idle so the orb doesn't move.
            ZStack {
                if triageActive {
                    TriageProgressBar(
                        progress: engine.triage.fraction,
                        caption: "Catching up · \(engine.triage.done) of \(engine.triage.inWindow)",
                        trailing: triageDateLabel
                    )
                    .padding(.horizontal, Space.s6)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Space.s8 + Space.s6)
            .animation(.easeInOut(duration: 0.25), value: triageActive)

            // Active: hold to talk; the waveform tracks the live mic while listening,
            // or the agent's speech while it's talking back.
            OrbView(
                level: orbLevel,
                onPressStart: {
                    session.bargeIn.stop()
                    speaker.stop()
                    // Tapping the orb while a previous turn is still transcribing aborts
                    // it and does NOT begin a new recording — the user must tap&hold
                    // again to speak. Otherwise, start push-to-talk capture.
                    if listening.isTranscribing {
                        listening.cancel()
                    } else {
                        listening.start(engine: engine, manager: voice)
                    }
                },
                onPressEnd: { listening.stop() }
            )

            // While listening, the caption is replaced by live pink audio bars +
            // the running transcript.
            Group {
                if listening.isListening {
                    VStack(spacing: Space.s2) {
                        PinkAudioBars(level: listening.level)
                        if !listening.transcript.isEmpty {
                            Text(listening.transcript)
                                .font(AppFont.sm)
                                .foregroundStyle(theme.palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } else {
                    VStack(spacing: Space.s1) {
                        HStack(spacing: Space.s2) {
                            Image(systemName: "mic.fill")
                                .font(AppFont.xs(.semibold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: theme.palette.ringColors,
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    )
                                )
                            Text("Talk to me")
                                .font(AppFont.sm)
                                .foregroundStyle(theme.palette.textTertiary)
                        }
                        Text("push orb to talk")
                            .font(AppFont.xs)
                            .foregroundStyle(theme.palette.panelRadius != nil ? theme.palette.textTertiary : theme.palette.textMuted)
                    }
                    .grooveCapsule()
                }
            }
            .frame(minHeight: 44)
            .padding(.top, Space.s6)

            // Mic denied / unavailable — a small, non-blocking status under the orb.
            if let msg = session.micAccess.statusText {
                MicStatusBadge(text: msg)
                    .padding(.horizontal, Space.s6)
                    .padding(.top, Space.s3)
                    .transition(.opacity)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pageBackground()
        // Top-right: launch the native NEON STRIKE space shooter (full-screen SceneKit).
        .overlay(alignment: .topTrailing) {
            Button { showGame = true } label: {
                Image(systemName: "gamecontroller.fill")
                    .font(AppFont.lg)
                    .foregroundStyle(
                        LinearGradient(
                            colors: theme.palette.ringColors,
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .accessibilityLabel("Play Space Shooter")
        }
        // Top-left: car-mode toggle. ON (car) = the full hands-free brief; OFF (normal)
        // = a terse spoken headline. Forced ON while a CarPlay head unit is connected.
        .overlay(alignment: .topLeading) {
            Button {
                voice.toggleCarMode()
                session.flashStatus(voice.effectiveCarMode ? "Car mode on. You get full briefs." : "Car mode off. You get short briefs.")
            } label: {
                Image(systemName: voice.effectiveCarMode ? "car.fill" : "car")
                    .font(AppFont.lg)
                    .foregroundStyle(
                        voice.effectiveCarMode
                            ? AnyShapeStyle(LinearGradient(
                                colors: theme.palette.ringColors,
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(theme.palette.textMuted)
                    )
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .disabled(voice.carPlayConnected)
            .accessibilityLabel(voice.effectiveCarMode ? "Car mode on" : "Car mode off")
        }
        .fullScreenCover(isPresented: $showGame) { SpaceShooterGameScreen() }
        // While the agent speaks — a command reply or a brief — keep the mic open for
        // "cancel/stop/ok"; tear it down the moment speech ends. The spotter is armed
        // ahead of speech by `armDialog()` (mic-before-voice); the start here is a
        // no-op fallback for paths that reached speech without it.
        .onChange(of: speaker.isSpeaking) { _, speaking in
            if speaking {
                session.bargeIn.start()
            } else {
                session.bargeIn.stop()
            }
        }
        .onDisappear { session.suspend() }
        .onAppear {
            session.bind(engine: engine, voice: voice, speaker: speaker, router: router)
            promptLabel = BridgePrompts.random()
            // Preload the on-device voice (once) when the Bridge opens — not at app
            // launch, where starting the audio engine collided with the engine boot.
            // This still has it ready before the first tap.
            engine.warmUpVoiceOnce(pref: voice.ttsPref, hasKey: voice.canUseOpenAI)
            // A finished transcript → the tool-using agent (read/mark/archive + follow-ups).
            listening.onFinal = { transcript in session.handleCommand(transcript) }
            // Push-to-talk reports its mic/speech access → drives the status badge.
            listening.onAccess = { access in session.setMicAccess(access) }
            // Clear a stale denial badge if the user has since enabled access in Settings.
            session.refreshMicAccess()
        }
    }
}

/// Playful, attention-grabbing labels for the Bridge prompt button — one is picked at
/// random each time the screen appears so the button feels alive and inviting.
enum BridgePrompts {
    static let all = [
        "Hey, whatsupp",
        "Pick me!",
        "Tap for the tea",
        "What'd I miss?",
        "Catch me up",
        "Spill the news",
        "Brief me, boss",
        "Psst… tap here",
        "What's the scoop?",
        "Give me a tap",
        "Hit me up",
        "The latest, please",
        "Tap me, I'm shy",
        "Story time?",
        "Anything new?",
    ]
    static func random() -> String { all.randomElement() ?? "Hey, whatsupp" }
}

/// The Bridge prompt button. Tapping speaks the team SITREP; while held it shows a
/// shimmering sweep in the app's standard ring gradient and an animated gradient
/// border. Glows while the reply is being spoken.
struct TldrButton: View {
    @Environment(\.theme) private var theme
    var label: String = "Hey, whatsupp"
    var isGenerating: Bool = false
    var isSpeaking: Bool = false
    var action: () -> Void = {}

    @State private var pressed = false
    @State private var start = Date()

    private var p: ThemePalette { theme.palette }

    var body: some View {
        content
            .scaleEffect(pressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { _ in pressed = false; action() }
            )
    }

    private var content: some View {
        HStack(spacing: Space.s2) {
            Group {
                if isGenerating {
                    GradientSpinner(size: 15)
                } else {
                    Image(systemName: isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .font(AppFont.base(.semibold))
                        .foregroundStyle(p.keycapLabel(.primary, or: kElectricBlue))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 17, height: 17)
            Text(label)
                .font(AppFont.mono(15, .semibold))
                .foregroundStyle(p.keycapLabel(.primary, or: p.textPrimary))
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .background {
            // Groovebox draws the lavender dome keycap outside the clip (below).
            if p.primaryKeycap == nil {
                LinearGradient(colors: [p.bgRaised, p.bgElevated], startPoint: .top, endPoint: .bottom)
                    .overlay(
                        LinearGradient(colors: [.bevel(0.10), .clear], startPoint: .top, endPoint: .center)
                    )
            }
        }
        // The lively pressed look — a ring-gradient shimmer sweep — also plays while
        // the Bridge is speaking, so the button visibly "talks" with the reply.
        .overlay { if pressed || isSpeaking { shimmer } }
        .overlay(
            Capsule(style: .continuous)
                .stroke(strokeStyle, lineWidth: (pressed || isSpeaking) ? 1.5 : 1)
        )
        .clipShape(Capsule(style: .continuous))
        .keycapSurface(.primary, radius: Radius.full)
        .shadow(
            color: pressed ? kPink.opacity(0.4) : (isSpeaking ? p.bridgeAccent.opacity(0.45) : .black.opacity(0.3)),
            radius: (pressed || isSpeaking) ? 12 : 6, y: 2
        )
    }

    private var strokeStyle: AnyShapeStyle {
        if pressed || isGenerating || isSpeaking {
            return AnyShapeStyle(p.ringGradient)
        }
        return AnyShapeStyle(p.primaryKeycap == nil ? p.borderStrong : .clear)
    }

    /// A ring-gradient band sweeping across the button while pressed.
    private var shimmer: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            GeometryReader { geo in
                let w = geo.size.width
                LinearGradient(colors: p.ringColors, startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.55)
                    .blur(radius: 10)
                    .offset(x: CGFloat(sin(t * 3.2) * 0.5 + 0.5) * (w * 1.4) - w * 0.45)
                    .blendMode(.screen)
                    .opacity(0.85)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small, tappable follow-up chip shown under the Bridge prompt — used for the
/// progressive "Check tomorrow" and "Highlights of the week" links. Subtle pill with
/// an electric-blue glyph; the whole row fades in/out as links come and go.
struct BridgeQuickLink: View {
    @Environment(\.theme) private var theme
    var icon: String
    var label: String
    /// Expand to fill the available width (so a row of chips shares it equally).
    var fillWidth: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s1 + 1) {
                Image(systemName: icon)
                    .font(AppFont.xs3(.semibold))
                    .foregroundStyle(theme.palette.bridgeAccent)
                Text(label)
                    .font(AppFont.xs2(.medium))
                    .foregroundStyle(theme.palette.keycapLabel(.secondary, or: theme.palette.textSecondary))
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s1 + 2)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .keycapSurface(.secondary, radius: Radius.full) {
                Capsule(style: .continuous)
                    .fill(theme.palette.bgRaised.opacity(0.6))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(theme.palette.borderStrong, lineWidth: 1)
                    )
            }
        }
        .buttonStyle(PressableLinkStyle())
    }
}

/// A small inline status shown under the orb when the microphone is denied or
/// unavailable — amber (actionable warning), `mic.slash` glyph, soft tinted card.
struct MicStatusBadge: View {
    @Environment(\.theme) private var theme
    var text: String

    private var p: ThemePalette { theme.palette }

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "mic.slash.fill")
                .font(AppFont.xs2(.semibold))
                .foregroundStyle(p.accentAmber)
            Text(text)
                .font(AppFont.xs)
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Groovebox: a solid island panel, not a tinted wash.
            RoundedRectangle(cornerRadius: p.panelRadius ?? 10, style: .continuous)
                .fill(p.panelRadius == nil ? p.accentAmber.opacity(0.10) : p.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: p.panelRadius ?? 10, style: .continuous)
                .stroke(p.accentAmber.opacity(0.25), lineWidth: 1)
        )
    }
}

/// A gentle press response (scale + dim) for the Bridge follow-up chips.
private struct PressableLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A small rotating arc in the app's standard ring gradient — the "generating"
/// loading indicator while the agent composes its reply.
struct GradientSpinner: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = 16

    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.72)
            .stroke(
                theme.palette.ringGradient,
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            // CADisplayLink-backed repeat, not TimelineView(.animation): the latter
            // never starts ticking when the view mounts against snapshot-flipped
            // window traits during a background→foreground push (notification tap).
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}

/// Live pink audio bars shown while the Bridge is listening — a row of capsules that
/// dance with the mic `level`, each with its own wobble so it reads as voice.
struct PinkAudioBars: View {
    @Environment(\.theme) private var theme
    var level: Double
    var barCount: Int = 7

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince(start)
            HStack(spacing: Space.s1 + 1) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        // Groovebox: each bar takes the next pastel of the rainbow.
                        .fill(theme.palette.orbRainbow.map { $0[i % $0.count] } ?? kPink)
                        .frame(width: 4, height: barHeight(i, t))
                }
            }
            .shadow(color: kPink.opacity(0.5), radius: 5)
        }
        .frame(height: 36)
    }

    private func barHeight(_ i: Int, _ t: TimeInterval) -> CGFloat {
        let phase = Double(i) * 0.9
        let wobble = sin(t * 6 + phase) * 0.5 + 0.5            // 0…1
        let h = 5 + level * 30 * (0.35 + 0.65 * wobble)
        return max(5, CGFloat(h))
    }
}

/// Groovebox: the live status line sits on a solid capsule while it has text, so
/// it reads over the grid. No-op otherwise (and in other themes).
private struct StatusCapsule: ViewModifier {
    let visible: Bool
    func body(content: Content) -> some View {
        if visible { content.grooveCapsule() } else { content }
    }
}
