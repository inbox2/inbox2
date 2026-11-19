import AVFoundation
import Speech
import SwiftUI

/// The shared hands-free break-in engine: every TTS surface that wants voice
/// interruption owns one of these. While the app speaks, the spotter keeps the mic
/// open — routed through the voice-processing I/O unit so acoustic echo cancellation
/// strips the app's own voice from the captured signal — and runs on-device speech
/// recognition (private, low-latency, never the network). The first whole vocabulary
/// word freshly heard fires `onKeyword`, once per run.
///
/// If recognition or permissions are unavailable it simply no-ops, so callers treat
/// break-in as a purely additive convenience layer on top of tap-to-stop. The Bridge
/// uses it directly with the universal `stopWords`; `TriageListener` layers the
/// read-aloud triage vocabulary ("trash" / "archive" / dismissals) on top.
@MainActor
final class KeywordSpotter: ObservableObject {
    /// The universal stop-words: speaking one of these while any TTS surface talks
    /// halts the speech. Vocabularies with their own keywords union these in so
    /// "stop" works the same everywhere. Mirrored on Android (`BargeInListener`).
    static let stopWords: Set<String> = ["cancel", "stop", "ok", "okay", "enough"]

    /// Smoothed mic level, 0…1 — only published when metering (drives listening orbs).
    @Published private(set) var level: Double = 0
    @Published private(set) var isListening = false

    /// Called with the matched word the first time one is heard in a run.
    var onKeyword: ((String) -> Void)?

    /// The live voice-processing engine, exposed so dialog TTS (Kokoro) can attach its
    /// player node. Audio rendered INTO this engine is the voice unit's OWN output —
    /// played at full call-downlink level and used as the AEC reference — instead of
    /// "other audio", which the VP unit attenuates and ducks (that made spoken briefs
    /// markedly quieter than plain playback). `nil` while not running, so callers fall
    /// back to their own engine.
    var playbackEngine: AVAudioEngine? { running ? engine : nil }

    private let vocabulary: Set<String>
    private let asksPermission: Bool
    private let metersLevel: Bool

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    /// Fire `onKeyword` at most once per run (until the next `start`).
    private var fired = false

    /// - Parameters:
    ///   - vocabulary: whole words that fire `onKeyword`. Defaults to the universal
    ///     stop-words, which is all a plain "interrupt my TTS" surface needs.
    ///   - asksPermission: when true, mic + speech authorization are requested on
    ///     `start()` (for surfaces that can be the user's first voice interaction);
    ///     when false the spotter runs only if both are already granted (the
    ///     push-to-talk flow requests them) and silently no-ops otherwise — a TTS
    ///     button tap should never spring a mic permission dialog.
    ///   - metersLevel: publish a smoothed RMS `level` for a listening orb.
    init(vocabulary: Set<String> = KeywordSpotter.stopWords,
         asksPermission: Bool = false, metersLevel: Bool = false) {
        self.vocabulary = vocabulary
        self.asksPermission = asksPermission
        self.metersLevel = metersLevel
    }

    /// Begin listening. Requires on-device recognition; permissions are requested or
    /// required-granted per `asksPermission`. No-ops when anything is unavailable.
    func start() {
        guard !running else { return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return }
        if asksPermission {
            requestPermissions { [weak self] granted in
                guard let self, granted, !self.running else { return }
                self.beginEngine()
            }
        } else {
            guard SFSpeechRecognizer.authorizationStatus() == .authorized,
                  AVAudioApplication.shared.recordPermission == .granted else { return }
            beginEngine()
        }
    }

    func stop() {
        guard running || task != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        running = false
        isListening = false
        if metersLevel { withAnimation(.easeOut(duration: 0.2)) { level = 0 } }
    }

    private func beginEngine() {
        fired = false
        do {
            let input = engine.inputNode
            // Acoustic echo cancellation: route the mic through the voice-processing I/O
            // unit so the TTS coming out of the speaker is cancelled from the captured
            // signal (otherwise the app would hear itself speak a stop-word — including
            // the read-aloud's own "trash, archive…?" prompt). Two quality guards:
            //   - On headphones the echo path doesn't exist (the TTS plays in the
            //     user's ears, not into the mic) — skip the voice-processing unit
            //     entirely so playback keeps its full quality.
            //   - On the built-in speaker AEC is required, but the VP unit by default
            //     also DUCKS "other audio" — which is our own TTS: it squashed and
            //     muffled the spoken brief whenever the mic was open over it. Keep the
            //     echo cancellation, turn the ducking down to minimum (iOS 17+).
            // Materialize the output chain (mainMixer → output) BEFORE starting, so
            // the dialog TTS can attach a player node to a graph that already renders
            // — and so voice processing can be enabled on the output node too (the VP
            // unit requires input and output to agree within one engine).
            engine.mainMixerNode.outputVolume = 1
            // The voice-processing toggle below rebuilds the engine graph, which can
            // raise an ObjC NSException from AVAudioEngineGraph::_Connect while the
            // session/route is still settling — and Swift's `try?` can NOT catch it
            // (field crash: SIGABRT). Run the toggle through the ObjC catcher so a
            // raise degrades to "no barge-in this turn" instead of an abort. NO format
            // pre-check here: a fresh input node reports 0 Hz until the VP unit
            // materializes the hardware format, so checking before the toggle bailed
            // on perfectly good starts (it killed the read-aloud triage window); the
            // post-toggle guard before installTap below is the real format gate.
            let onSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs
                .contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
            if let raised = Inbox2CatchException({
                if onSpeaker {
                    try? input.setVoiceProcessingEnabled(true)
                    try? engine.outputNode.setVoiceProcessingEnabled(true)
                    if #available(iOS 17.0, *) {
                        // Advanced ducking = voice-activity-driven: the TTS plays at full
                        // level while nobody talks (static ducking squashed every brief),
                        // and ducks hard the moment the mic hears live speech — exactly
                        // when a break-in word needs the acoustic headroom to be
                        // recognized. (A fixed .min duck kept quality but drowned the
                        // user's "stop" under the full-volume brief.)
                        input.voiceProcessingOtherAudioDuckingConfiguration =
                            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                                enableAdvancedDucking: true, duckingLevel: .max)
                    }
                } else {
                    try? input.setVoiceProcessingEnabled(false)
                    try? engine.outputNode.setVoiceProcessingEnabled(false)
                }
            }) {
                Log.engine.error("keyword spotter: voice-processing toggle raised \(raised, privacy: .public)")
                stop()
                return
            }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true
            request = req
            task = recognizer?.recognitionTask(with: req) { [weak self] result, _ in
                guard let self, let result else { return }
                let text = result.bestTranscription.formattedString.lowercased()
                Task { @MainActor in self.scan(text) }
            }

            let format = input.outputFormat(forBus: 0)
            // installTap raises an uncatchable ObjC exception (not a Swift error) on an
            // invalid format — which the input node reports (0 Hz / 0 ch) while the
            // audio session/route isn't ready. Crashed the app in the field; bail soft.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                Log.engine.error("keyword spotter: input format unavailable (\(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch)")
                stop()
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
                guard let self, self.metersLevel else { return }
                let rms = MicLevel.rms(buffer)
                Task { @MainActor in self.ingest(rms) }
            }
            engine.prepare()
            try engine.start()
            running = true
            isListening = true
        } catch {
            Log.engine.error("keyword spotter start failed: \(String(describing: error), privacy: .public)")
            stop()
        }
    }

    /// Match a whole vocabulary word in the latest transcript. Whole-word (not
    /// substring) so "stopwatch" or "okra" don't trigger; the tail is checked so only
    /// a freshly-spoken word fires.
    private func scan(_ text: String) {
        guard !fired else { return }
        let words = text.split { !$0.isLetter }.map(String.init)
        guard let hit = words.last(where: { vocabulary.contains($0) }) else { return }
        fired = true
        onKeyword?(hit)
    }

    private func ingest(_ rms: Float) { level = MicLevel.smooth(level, rms: rms) }

    /// Mic + on-device speech authorization (both needed before capture). Already-granted
    /// is the common case once the Bridge has been used; otherwise we ask once.
    private func requestPermissions(_ done: @escaping (Bool) -> Void) {
        let mic: (@escaping (Bool) -> Void) -> Void = { cb in
            switch AVAudioApplication.shared.recordPermission {
            case .granted: cb(true)
            case .denied: cb(false)
            default: AVAudioApplication.requestRecordPermission { ok in Task { @MainActor in cb(ok) } }
            }
        }
        mic { granted in
            guard granted else { done(false); return }
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: done(true)
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { status in
                    Task { @MainActor in done(status == .authorized) }
                }
            default: done(false)
            }
        }
    }
}
