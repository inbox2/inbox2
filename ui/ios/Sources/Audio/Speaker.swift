import AVFoundation
import NaturalLanguage
import SwiftUI

/// A selectable Apple on-device voice, or "Automatic" (id == ""). Automatic picks the
/// best installed voice for whatever language each segment is in (so it's the
/// multilingual / international default); a specific pick is used for its own language
/// and Automatic fills in for any other language detected in the text.
struct AppleVoiceOption: Identifiable, Hashable {
    let id: String        // AVSpeechSynthesisVoice.identifier; "" = Automatic
    let name: String
    let language: String  // e.g. "en-US"
    let qualityRank: Int  // 3 premium · 2 enhanced · 1 default

    var isAuto: Bool { id.isEmpty }
    var qualityTag: String { qualityRank >= 3 ? "Premium" : (qualityRank == 2 ? "Enhanced" : "") }
    var label: String {
        if isAuto { return "Automatic · best, multilingual" }
        let q = qualityTag.isEmpty ? "" : " · \(qualityTag)"
        return "\(name) · \(language)\(q)"
    }
}

enum AppleVoices {
    static let automatic = AppleVoiceOption(id: "", name: "Automatic", language: "", qualityRank: 0)

    /// All installed voices (Automatic first), grouped by language, best quality first.
    /// The retro low-quality "Eloquence" set is hidden.
    static func installed() -> [AppleVoiceOption] {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.identifier.lowercased().contains("eloquence") }
            .map { AppleVoiceOption(id: $0.identifier, name: $0.name, language: $0.language, qualityRank: $0.quality.rawValue) }
            .sorted { a, b in
                if a.language != b.language { return a.language < b.language }
                if a.qualityRank != b.qualityRank { return a.qualityRank > b.qualityRank }
                return a.name < b.name
            }
        return [automatic] + voices
    }

    /// The voice to speak `language` in — honoring the user's chosen voice when it
    /// matches that language, otherwise the best installed voice for it (premium →
    /// enhanced → default), falling back to en-US.
    static func best(for language: String, preferredId: String) -> AVSpeechSynthesisVoice? {
        let base = String(language.prefix(2))
        if !preferredId.isEmpty, let v = AVSpeechSynthesisVoice(identifier: preferredId),
           v.language.hasPrefix(base) {
            return v
        }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(base) }
        let best = candidates.max { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue < b.quality.rawValue }
            return (a.language == language ? 1 : 0) < (b.language == language ? 1 : 0)
        }
        return best ?? AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

/// Text-to-speech for the Bridge. Routes per `VoiceEngineManager`: Apple
/// `AVSpeechSynthesizer` (on-device, free) or OpenAI `tts-1` (natural voice, played
/// back with metering). Either way it publishes `isSpeaking` (button glow) and an
/// amplitude `level` (0…1) so the orb waveform "shows" what the agent is saying.
/// `stop()` cuts off mid-sentence.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    /// True while we're fetching OpenAI TTS audio (before playback starts) — drives
    /// the button's loading spinner so there's no silent gap.
    @Published private(set) var isPreparing = false
    /// True during a mid-utterance Kokoro stream stall — playback ran dry while the
    /// next chunk is still synthesizing. The orbs morph into a spinner for the gap.
    @Published private(set) var isBuffering = false
    /// Playback amplitude (0…1). NOT `@Published`: it updates at audio-frame rate, so it
    /// flows through the shared `AudioLevels` sink (observed only by the meter views)
    /// instead of re-rendering everything that observes the `Speaker`. The internal decay
    /// math still reads/writes it directly; the `didSet` mirrors each change to the sink.
    private var level: Double = 0 { didSet { AudioLevels.shared.setSpeaker(level) } }

    /// When true, TTS activates a `.playAndRecord` session (instead of `.playback`)
    /// so a `KeywordSpotter` can keep the mic open for "cancel/stop/ok" while the
    /// agent talks. Set by the Bridge for all its speech (briefs included) and by the
    /// read-aloud flow; off for the plain voice tester.
    var dialogMode = false

    /// Fetches the barge-in spotter's live voice-processing engine (nil when it isn't
    /// running). In dialog mode Kokoro attaches its player node THERE, so the TTS is
    /// the voice unit's own output — full level and the AEC reference — instead of
    /// "other audio", which the VP unit attenuates and ducks (briefs played markedly
    /// quieter than plain reads). Set by the Bridge alongside `dialogMode`.
    var dialogPlaybackEngine: (() -> AVAudioEngine?)?

    private let synth = AVSpeechSynthesizer()
    /// Eases `level` down between bumps — shared by the Apple lane (per-word) and the
    /// Kokoro streaming lane (per-chunk RMS).
    private var levelDecay: Timer?
    /// Outstanding Apple utterances (a locale-aware reply enqueues one per language
    /// run); isSpeaking stays true until the last one finishes.
    private var appleQueued = 0

    private var player: AVAudioPlayer?
    private var meter: Timer?

    /// The free / Kokoro streaming lane — a per-utterance engine + a cancel token shared
    /// with the running synthesis. Both nil unless a Kokoro brief is in flight.
    private var kokoroPlayer: KokoroStreamPlayer?
    private var kokoroCancel: KokoroCancelToken?

    override init() {
        super.init()
        synth.delegate = self
        registerAudioObservers()
    }

    /// Speak `text` using the source the user selected. OpenAI TTS is fetched through
    /// the shared core (`engine.bridgeOpenAITTS`), played back here with metering.
    /// `surface` resolves the lane voice — the read-aloud reader can use a different
    /// voice than the Bridge dialog.
    func speak(_ text: String, using manager: VoiceEngineManager, engine: EngineModel,
               surface: VoiceSurface = .bridge) {
        let t = Self.droppingLargeNumbers(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // The core resolves the actual lane from the user's preference + device
        // support + downloaded models + key validity.
        let lane = engine.effectiveLane("tts", pref: manager.ttsPref, hasKey: manager.canUseOpenAI)
        switch lane {
        case "openai":
            isPreparing = true   // loading until the audio actually starts
            Task {
                switch await engine.bridgeOpenAITTS(key: manager.openAIKey, text: t, voice: manager.openAIVoice(for: surface)) {
                case .success(let data):
                    isPreparing = false
                    playOpenAI(data)
                case .failure(let err):
                    isPreparing = false
                    // Don't fail silently — speak the error (on-device voice) so the
                    // user knows to fix the key.
                    Log.engine.error("OpenAI TTS failed: \(err.message, privacy: .public)")
                    speakApple("OpenAI returned the error: \(err.message). Go into settings and update or disable your key.", preferredVoiceId: manager.appleVoiceId)
                }
            }
        case "free":
            // Stream the downloaded Kokoro (sherpa-onnx) voice: synthesize segment by
            // segment and play each chunk as it arrives, so a multi-sentence brief starts
            // speaking after the first segment instead of the whole utterance. Falls back
            // to the non-streaming path, then the Apple voice, if anything goes wrong.
            guard let dir = engine.modelPath(BridgeModelIDs.kokoro) else { speakApple(t); return }
            isPreparing = true
            speakKokoroStreaming(t, modelDir: dir, speakerId: manager.kokoroVoiceId(for: surface),
                                 appleVoiceId: manager.appleVoiceId(for: surface))
        default: // "native" / "needs-download"
            speakApple(t, preferredVoiceId: manager.appleVoiceId(for: surface))
        }
    }

    /// Speak with the on-device voice regardless of the configured TTS source — used
    /// for error guidance that must be heard even when OpenAI is failing.
    func speakSystem(_ text: String) { speakApple(text) }

    /// Numbers above this aren't worth listening to — order numbers, tracking codes,
    /// ticket IDs — the voice reads them digit by digit for seconds. Mirrors the core's
    /// `sanitize_spoken` (which covers core-generated speech); this covers the texts
    /// the app voices directly, like the reader's stored triage summaries.
    private static let maxSpokenNumber: UInt64 = 10_000
    static func droppingLargeNumbers(_ s: String) -> String {
        var out = ""
        var run = ""
        func flush() {
            // Keep small runs; drop large ones (a run too long to parse counts as large).
            // Grouped figures like "15,000" survive — the separator splits the runs.
            if let n = UInt64(run), n <= maxSpokenNumber { out += run }
            run = ""
        }
        for ch in s {
            if ch.isASCII && ch.isWholeNumber {
                run.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }

    /// Bring the dialog (`.playAndRecord`) session up ahead of speech. Callers that arm
    /// a keyword spotter must sequence session → spotter → `speak`: the spotter's
    /// voice-processing mic engine rebuilds the audio hardware graph, and bringing it up
    /// after playback has begun swallows the first ~second of the utterance.
    func prepareDialogSession() {
        dialogMode = true
        activatePlaybackSession()
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        meter?.invalidate(); meter = nil
        levelDecay?.invalidate(); levelDecay = nil
        appleQueued = 0
        // Barge-in for the Kokoro stream: abort the in-flight synthesis (callback → 0) and
        // flush the player node's scheduled buffers.
        kokoroCancel?.cancel()
        kokoroPlayer?.stop()
        kokoroPlayer = nil
        kokoroCancel = nil
        isSpeaking = false
        isPreparing = false
        isBuffering = false
        level = 0
    }

    // MARK: - Apple (AVSpeechSynthesizer)

    /// Speak with the on-device Apple voice. The text is split into runs by detected
    /// language (NaturalLanguage) and each run is enqueued with a matching voice —
    /// so an English briefing that names a Dutch meeting reads the Dutch part in a
    /// Dutch voice when one is installed. `preferredVoiceId` ("" = Automatic) is used
    /// for its own language; other languages fall back to the best installed voice.
    ///
    /// On a physical device the session may be inactive (a prior listening turn calls
    /// setActive(false)) or honor the silent switch — so force an active .playback
    /// session first, like the OpenAI/Kokoro path.
    private func speakApple(_ text: String, preferredVoiceId: String = "") {
        activatePlaybackSession()
        let segments = Self.languageSegments(text)
        appleQueued = segments.count
        if appleQueued > 0 {
            isSpeaking = true
            startLevelDecay()
        }
        for seg in segments {
            let u = AVSpeechUtterance(string: seg.text)
            u.voice = AppleVoices.best(for: seg.language, preferredId: preferredVoiceId)
            synth.speak(u)
        }
    }

    /// Split `text` into consecutive same-language runs. Detection is per sentence
    /// (reliable granularity) and only trusted above a confidence threshold; short or
    /// uncertain spans default to en-US, so only a clearly non-English sentence/title
    /// switches voice.
    private static func languageSegments(_ text: String) -> [(text: String, language: String)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var runs: [(String, String)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range])
            let lang = dominantLanguage(of: s)
            if let last = runs.last, last.1 == lang {
                runs[runs.count - 1].0 += s
            } else {
                runs.append((s, lang))
            }
            return true
        }
        if runs.isEmpty { return [(text, dominantLanguage(of: text))] }
        return runs.map { (text: $0.0, language: $0.1) }
    }

    private static func dominantLanguage(of s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return "en-US" }
        let r = NLLanguageRecognizer()
        r.processString(trimmed)
        guard let (lang, prob) = r.languageHypotheses(withMaximum: 1).first, prob > 0.65 else {
            return "en-US"
        }
        return lang.rawValue
    }

    /// Put the shared audio session into a spoken-audio `.playback` state so TTS is
    /// audible on device (ignores the silent switch) and recovers from a listening
    /// turn that deactivated the session.
    private func activatePlaybackSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            if dialogMode {
                // Coexist with the barge-in mic: playback to the speaker while recording
                // stays available. AEC is enabled on the listener's input node.
                try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth])
            } else {
                try session.setCategory(.playback, mode: .spokenAudio)
            }
            try session.setActive(true)
        } catch {
            Log.engine.error("audio session activate failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func startLevelDecay() {
        levelDecay?.invalidate()
        levelDecay = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.level *= 0.82
                if self.level < 0.01 { self.level = 0 }
            }
        }
    }

    private func stopLevelDecay() { levelDecay?.invalidate(); levelDecay = nil; level = 0 }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in isSpeaking = true; startLevelDecay() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in level = Double.random(in: 0.55...0.95) }   // bump per word
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            // Stay "speaking" until the last queued language run finishes.
            appleQueued -= 1
            if appleQueued <= 0 { appleQueued = 0; isSpeaking = false; stopLevelDecay() }
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in appleQueued = 0; isSpeaking = false; stopLevelDecay() }
    }

    // MARK: - Free / Kokoro (streaming AVAudioEngine)

    /// Stream Kokoro: load the engine (for its sample rate), then synthesize segment by
    /// segment, scheduling each chunk onto an `AVAudioPlayerNode` as it arrives. A fresh
    /// cancel token per utterance makes any late callback from a superseded run inert.
    private func speakKokoroStreaming(_ text: String, modelDir: String, speakerId: Int, appleVoiceId: String) {
        let token = KokoroCancelToken()
        kokoroCancel = token
        Task {
            let sampleRate = await KokoroCache.shared.prepare(modelDir: modelDir)
            guard token === kokoroCancel else { return }   // barged in before we started
            guard sampleRate > 0 else {
                // SDK absent / model not loadable → existing Apple fallback.
                isPreparing = false
                kokoroCancel = nil
                speakApple(text, preferredVoiceId: appleVoiceId)
                return
            }
            activatePlaybackSession()
            let shared = dialogMode ? dialogPlaybackEngine?() : nil
            let player = KokoroStreamPlayer(sampleRate: sampleRate, sharedEngine: shared)
            kokoroPlayer = player
            player.onFirstBuffer = { [weak self] in
                Task { @MainActor in
                    guard let self, token === self.kokoroCancel else { return }
                    self.isPreparing = false
                    self.isSpeaking = true
                    self.startLevelDecay()
                }
            }
            player.onLevel = { [weak self] lvl in
                Task { @MainActor in
                    guard let self, token === self.kokoroCancel else { return }
                    self.level = max(self.level, lvl)   // decay timer eases it down between chunks
                }
            }
            player.onStall = { [weak self] stalled in
                Task { @MainActor in
                    guard let self, token === self.kokoroCancel else { return }
                    self.isBuffering = stalled
                }
            }
            player.onDrained = { [weak self] in
                Task { @MainActor in self?.finishKokoro(token) }
            }

            let emitted = await KokoroCache.shared.synthesizeStreaming(
                text, modelDir: modelDir, speakerId: speakerId, cancel: token,
                onChunk: { chunk in player.schedule(chunk); return true })

            guard token === kokoroCancel else { return }   // barged in during synthesis
            if emitted == 0 {
                // First-chunk failure / empty audio → non-streaming Generate, then Apple.
                player.stop()
                kokoroPlayer = nil
                await kokoroFallback(text, modelDir: modelDir, speakerId: speakerId,
                                     appleVoiceId: appleVoiceId, token: token)
            } else {
                player.synthesisFinished()   // flips isSpeaking off once buffers drain
            }
        }
    }

    /// The streaming path produced nothing — try the whole-utterance synth (the old path),
    /// then the Apple voice. Never fails silently.
    private func kokoroFallback(_ text: String, modelDir: String, speakerId: Int,
                                appleVoiceId: String, token: KokoroCancelToken) async {
        let speech = await KokoroCache.shared.synthesize(text, modelDir: modelDir, speakerId: speakerId)
        guard token === kokoroCancel else { return }   // barged in during fallback synth
        isPreparing = false
        isBuffering = false
        kokoroCancel = nil
        if let s = speech, let wav = WAVWriter.data(samples: s.samples, sampleRate: s.sampleRate) {
            playOpenAI(wav)
        } else {
            speakApple(text, preferredVoiceId: appleVoiceId)
        }
    }

    /// Synthesis done and the player node drained — clear the Kokoro lane. Guarded so a
    /// drain from a superseded utterance can't clobber a newer one.
    private func finishKokoro(_ token: KokoroCancelToken) {
        guard token === kokoroCancel else { return }
        isSpeaking = false
        isPreparing = false
        isBuffering = false
        stopLevelDecay()
        kokoroPlayer?.stop()
        kokoroPlayer = nil
        kokoroCancel = nil
        level = 0
    }

    /// Tear down only the Kokoro lane (leaves the OpenAI/Apple lanes untouched) — used by
    /// the audio-session interruption / route-change / engine-config observers.
    private func stopKokoro() {
        guard kokoroPlayer != nil || kokoroCancel != nil else { return }
        kokoroCancel?.cancel()
        kokoroPlayer?.stop()
        kokoroPlayer = nil
        kokoroCancel = nil
        isSpeaking = false
        isPreparing = false
        isBuffering = false
        stopLevelDecay()
        level = 0
    }

    // MARK: - Audio session interruptions / route changes (Kokoro engine)

    /// The streaming engine — unlike `AVAudioPlayer` — doesn't recover from interruptions,
    /// route changes, or graph reconfiguration on its own, so tear the Kokoro lane down on
    /// each; the next brief builds a fresh engine.
    private func registerAudioObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleEngineConfigChange(_:)),
                       name: .AVAudioEngineConfigurationChange, object: nil)
    }

    @objc nonisolated private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in stopKokoro() }
    }

    @objc nonisolated private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        Task { @MainActor in stopKokoro() }   // e.g. headphones unplugged
    }

    @objc nonisolated private func handleEngineConfigChange(_ note: Notification) {
        Task { @MainActor in stopKokoro() }
    }

    // MARK: - OpenAI (AVAudioPlayer with metering)

    private func playOpenAI(_ data: Data) {
        do {
            activatePlaybackSession()
            let p = try AVAudioPlayer(data: data)
            p.isMeteringEnabled = true
            p.volume = 1.0
            p.delegate = self
            player = p
            p.play()
            isSpeaking = true
            meter?.invalidate()
            meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let pl = self.player, pl.isPlaying else { return }
                    pl.updateMeters()
                    let db = pl.averagePower(forChannel: 0)            // -160…0 dB
                    self.level = Double(max(0, min(1, (db + 50) / 50)))  // map ~-50…0 → 0…1
                }
            }
        } catch {
            Log.engine.error("OpenAI playback failed: \(String(describing: error), privacy: .public)")
            isSpeaking = false
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isSpeaking = false
            level = 0
            meter?.invalidate(); meter = nil
        }
    }
}
