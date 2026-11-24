import AVFoundation
import Speech
import SwiftUI

/// Captures the microphone while the user holds the Bridge orb (push-to-talk),
/// publishing a smoothed input level (0…1) for the orb waveform + pink bars. Speech
/// recognition routes per the resolved STT lane:
///   - **native**: Apple `SpeechAnalyzer`/`SpeechTranscriber` (iOS 26 — live partial
///     transcript, fully on-device, OS-managed model assets shared with dictation).
///   - **openai**: record the clip, transcribe on release via `gpt-4o-transcribe`.
/// One input tap feeds the RMS meter, the analyzer stream (native), and the recorded
/// buffer (openai). On release the final transcript is handed to `onFinal` — the
/// hand-off to the agent brain.
@MainActor
final class ListeningManager: ObservableObject {
    /// Smoothed mic level, 0…1.
    @Published private(set) var level: Double = 0
    @Published private(set) var isListening = false
    /// Live (partial) transcript while listening — native lane only.
    @Published private(set) var transcript = ""
    /// True while the release-time transcription resolves (native finalize / openai).
    @Published private(set) var isTranscribing = false

    /// Called once with the final transcript when listening stops (after any async
    /// transcription completes).
    var onFinal: ((String) -> Void)?

    /// Called with the resolved mic access whenever capture is attempted — lets the
    /// Bridge surface a "microphone is off / unavailable" badge instead of failing silently.
    var onAccess: ((MicAccess) -> Void)?

    private let engine = AVAudioEngine()

    // Native lane: one SpeechAnalyzer session per utterance.
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    /// Drains `transcriber.results` into `transcript`; completes when the analyzer
    /// finishes, so the release handoff can await the last finalized segment.
    private var resultsTask: Task<Void, Never>?
    /// Finalized (isFinal) segments so far — volatile results overwrite only the tail.
    private var finalized = ""
    private var finalizeTask: Task<Void, Never>?
    /// The in-flight recorded-clip transcription (openai), so a tap on the orb while
    /// it's still resolving can abort it without handing a transcript to the agent.
    private var transcribeTask: Task<Void, Never>?

    // Lane routing + recorded audio for the openai lane.
    private var lane: BridgeLane = .native
    private weak var engineRef: EngineModel?
    private weak var managerRef: VoiceEngineManager?
    private var recorded: [Float] = []
    private var hwSampleRate: Double = 48_000

    /// Resolve the STT lane from the user's preference and begin capture. The free
    /// (WhisperKit) lane is gone — SpeechAnalyzer made it redundant — so any stored
    /// `free` preference resolves to native.
    func start(engine eng: EngineModel, manager: VoiceEngineManager) {
        guard !isListening else { return }
        engineRef = eng
        managerRef = manager
        lane = (manager.sttPref == .openai && manager.canUseOpenAI) ? .openai : .native
        // SpeechAnalyzer is fully on-device and needs no speech-recognition
        // authorization (unlike the old SFSpeechRecognizer path) — just the mic.
        MicPermission.request(needsSpeech: false) { [weak self] access in
            guard let self else { return }
            self.onAccess?(access)
            guard access == .granted else { return }
            Task { @MainActor in await self.beginEngine() }
        }
    }

    func stop() {
        guard isListening else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isListening = false
        withAnimation(.easeOut(duration: 0.2)) { level = 0 }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        switch lane {
        case .native:
            // Close the input stream and let the analyzer finalize the tail of the
            // utterance, then hand off. The window counts as "transcribing" so a tap
            // on the orb can cancel it (see `cancel`).
            isTranscribing = true
            inputContinuation?.finish()
            finalizeTask = Task { @MainActor in
                try? await analyzer?.finalizeAndFinishThroughEndOfInput()
                // The results stream ends with the analyzer — wait for the drain task
                // so `transcript` holds the last finalized segment.
                await resultsTask?.value
                isTranscribing = false
                teardownNative()
                guard !Task.isCancelled else { return }
                onFinal?(transcript)
            }
        default:
            // openai — transcribe the recorded clip, then hand off.
            transcribeRecorded()
        }
    }

    /// Abort an in-flight transcription or native-finalize window without handing a
    /// transcript to the agent — the user tapped the orb again while it was still
    /// resolving. A fresh tap&hold is needed to speak again.
    func cancel() {
        finalizeTask?.cancel(); finalizeTask = nil
        transcribeTask?.cancel(); transcribeTask = nil
        if let analyzer {
            Task { try? await analyzer.cancelAndFinishNow() }
        }
        teardownNative()
        isTranscribing = false
        recorded.removeAll(keepingCapacity: true)
    }

    private func teardownNative() {
        inputContinuation = nil
        resultsTask = nil
        analyzer = nil
    }

    private func beginEngine() async {
        do {
            transcript = ""
            finalized = ""
            finalizeTask?.cancel(); finalizeTask = nil
            teardownNative()
            recorded.removeAll(keepingCapacity: true)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true)

            // Native lane: live on-device transcription via SpeechAnalyzer. The model
            // is an OS-managed asset (shared with keyboard dictation) — the install
            // request is a no-op once it's on the device.
            var analyzerFormat: AVAudioFormat?
            if lane == .native {
                let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                                                    transcriptionOptions: [],
                                                    reportingOptions: [.volatileResults],
                                                    attributeOptions: [])
                if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await install.downloadAndInstall()
                }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                    Log.engine.error("SpeechAnalyzer: no compatible audio format (assets missing?)")
                    onAccess?(.unavailable)
                    return
                }
                analyzerFormat = format
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                let a = SpeechAnalyzer(modules: [transcriber])
                try await a.start(inputSequence: stream)
                analyzer = a
                inputContinuation = continuation
                resultsTask = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            await MainActor.run {
                                guard let self else { return }
                                if result.isFinal { self.finalized += text }
                                self.transcript = self.finalized + (result.isFinal ? "" : text)
                            }
                        }
                    } catch {
                        Log.engine.error("SpeechTranscriber results failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }

            let input = engine.inputNode
            var format = input.outputFormat(forBus: 0)
            // The first start after launch often reads the route before the session
            // has settled (0 Hz), which ended the very first tap at once. Give it a
            // moment before giving up.
            for _ in 0..<20 where format.sampleRate == 0 || format.channelCount == 0 {
                try await Task.sleep(nanoseconds: 50_000_000)
                format = input.outputFormat(forBus: 0)
            }
            // installTap raises an uncatchable ObjC exception (not a Swift error) on an
            // invalid format — which the input node reports (0 Hz / 0 ch) while the
            // audio session/route isn't ready. Crashed the app in the field; bail soft.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                Log.engine.error("mic start: input format unavailable (\(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch)")
                cancel()
                return
            }
            hwSampleRate = format.sampleRate
            let recordClip = lane != .native
            // The tap runs on a realtime audio thread — capture the analyzer plumbing
            // locally so it never touches main-actor state. One AVAudioConverter is
            // reused across buffers (it keeps resampler state between calls).
            let continuation = inputContinuation
            let target = analyzerFormat
            let converter = target.flatMap { $0 == format ? nil : AVAudioConverter(from: format, to: $0) }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                if let continuation {
                    if let converter, let target {
                        if let converted = Self.convert(buffer, with: converter, to: target) {
                            continuation.yield(AnalyzerInput(buffer: converted))
                        }
                    } else {
                        continuation.yield(AnalyzerInput(buffer: buffer))
                    }
                }
                if recordClip { self?.appendSamples(buffer) }
                let rms = MicLevel.rms(buffer)
                Task { @MainActor in self?.ingest(rms) }
            }
            engine.prepare()
            try engine.start()
            isListening = true
        } catch {
            Log.engine.error("mic start failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Convert one tap buffer to the analyzer's preferred format (typically 16 kHz
    /// mono). The converter is reused across calls to keep resampler continuity.
    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer,
                                            with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var err: NSError?
        var fed = false
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return err == nil ? out : nil
    }

    /// Accumulate channel-0 PCM for the record-then-transcribe lane. The tap runs on
    /// a realtime audio thread; we hop the copied samples to the main actor (the tap is
    /// removed before `recorded` is read in `transcribeRecorded`).
    nonisolated private func appendSamples(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        let copy = Array(UnsafeBufferPointer(start: ch, count: n))
        Task { @MainActor [weak self] in self?.recorded.append(contentsOf: copy) }
    }

    /// Build a 16 kHz mono WAV from the clip and transcribe it via OpenAI.
    private func transcribeRecorded() {
        let samples = Self.resample(recorded, from: hwSampleRate, to: 16_000)
        guard samples.count > 1600, let wav = WAVWriter.data(samples: samples, sampleRate: 16_000) else {
            onFinal?("")
            return
        }
        isTranscribing = true
        let key = managerRef?.openAIKey ?? ""
        transcribeTask = Task {
            let text = await engineRef?.bridgeOpenAITranscribe(key: key, audio: wav)
            transcribeTask = nil
            isTranscribing = false
            // Cancelled by a tap on the orb while resolving — discard, don't hand off.
            guard !Task.isCancelled else { return }
            onFinal?(text ?? "")
        }
    }

    /// Naive decimation resample (mono). Good enough for speech at 16 kHz.
    private static func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, to > 0, !input.isEmpty else { return input }
        if abs(from - to) < 1 { return input }
        let ratio = from / to
        let outCount = Int(Double(input.count) / ratio)
        var out = [Float](); out.reserveCapacity(outCount)
        var pos = 0.0
        for _ in 0..<outCount {
            out.append(input[min(Int(pos), input.count - 1)])
            pos += ratio
        }
        return out
    }

    private func ingest(_ rms: Float) { level = MicLevel.smooth(level, rms: rms) }
}
