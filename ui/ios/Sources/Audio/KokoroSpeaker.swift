import Foundation

/// Shared Bridge model ids — must match the ids in the core manifest
/// (`bridge/models/models.json`). The host references downloaded models by these.
enum BridgeModelIDs {
    static let kokoro = "kokoro-multi-lang-v1"
    static let qwen = "qwen2.5-1.5b-instruct-q8"
    /// The free NLU lane's alternate variant — ~2x smaller and faster than Qwen,
    /// English-only, gated HuggingFace repo (its download needs the HF token).
    static let gemma = "gemma3-1b-it-int4"
    /// Not a downloadable model: the config/provenance id for Apple Foundation
    /// Models (the on-device native lane). Matches the core's `apple-fm` tag.
    static let appleFM = "apple-fm"
}

/// PCM produced by an on-device neural TTS engine. The player wraps it in a WAV
/// container and plays it back through the existing metering path.
struct NeuralSpeech: Sendable {
    let samples: [Float]   // mono, −1…1
    let sampleRate: Double
}

/// Per-utterance loudness normalizer for Kokoro output. Kokoro voices are mastered
/// quiet (peaks around 0.3–0.5; the default Nicole is a soft near-whisper), so the raw
/// floats play noticeably softer than the Apple/OpenAI lanes at the same hardware
/// volume. Boosts toward a target peak, tracking the running utterance peak so the
/// gain only ever tightens mid-utterance (no pumping), and clamps to ±1.
///
/// `@unchecked Sendable`: chunks arrive serially from the single synthesis pass, so
/// the running peak needs no lock.
final class KokoroGain: @unchecked Sendable {
    private static let targetPeak: Float = 0.9
    private static let maxBoost: Float = 3.0
    /// Floor so a near-silent first chunk can't send the gain to infinity.
    private var runningPeak: Float = 0.05

    func apply(_ samples: [Float]) -> [Float] {
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        runningPeak = max(runningPeak, peak)
        let gain = min(Self.maxBoost, Self.targetPeak / runningPeak)
        guard gain > 1.01 else { return samples }
        return samples.map { max(-1, min(1, $0 * gain)) }
    }
}

/// A selectable Kokoro voice. `id` is the sherpa-onnx speaker index — Kokoro orders
/// speakers alphabetically with American-female (af_*) first, then American-male (am_*),
/// then British (bf_/bm_). A curated, English-only subset led by the highest-grade
/// voices (see hexgrad Kokoro-82M VOICES.md). The user picks one in Voice output when
/// the Kokoro lane is selected; the choice persists in `VoiceEngineManager`.
struct KokoroVoice: Identifiable, Hashable {
    let id: Int
    let name: String
    let descriptor: String
    var label: String { "\(name) · \(descriptor)" }

    /// af_nicole — a soft, warm American-English female voice (the default).
    static let defaultId = 6

    static let catalog: [KokoroVoice] = [
        .init(id: 6,  name: "Nicole",   descriptor: "US · female"),   // grade B- (default)
        .init(id: 3,  name: "Heart",    descriptor: "US · female"),   // grade A
        .init(id: 2,  name: "Bella",    descriptor: "US · female"),   // grade A-
        .init(id: 1,  name: "Aoede",    descriptor: "US · female"),
        .init(id: 9,  name: "Sarah",    descriptor: "US · female"),
        .init(id: 5,  name: "Kore",     descriptor: "US · female"),
        .init(id: 16, name: "Michael",  descriptor: "US · male"),
        .init(id: 18, name: "Puck",     descriptor: "US · male"),
        .init(id: 14, name: "Fenrir",   descriptor: "US · male"),
        .init(id: 21, name: "Emma",     descriptor: "UK · female"),   // grade B-
        .init(id: 22, name: "Isabella", descriptor: "UK · female"),
        .init(id: 26, name: "George",   descriptor: "UK · male"),
        .init(id: 25, name: "Fable",    descriptor: "UK · male"),
    ]

    static func named(_ id: Int) -> KokoroVoice {
        catalog.first { $0.id == id } ?? catalog[0]
    }
}

/// The free-lane on-device TTS engine (Kokoro via sherpa-onnx), cached so the ~330 MB
/// model loads once. Synthesis runs off the main thread (actor executor). When the
/// sherpa-onnx SDK isn't linked (the `BRIDGE_KOKORO` compilation flag is unset) every
/// call returns `nil` and the Bridge falls back to the Apple voice.
///
/// Integration: vendor sherpa-onnx (the `sherpa-onnx.xcframework` + `onnxruntime`
/// xcframework + the `SherpaOnnx.swift` helper + bridging header), then add
/// `BRIDGE_KOKORO` to the target's `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. The model
/// downloads through the core manager into `model_path(kokoro)`.
actor KokoroCache {
    static let shared = KokoroCache()

    private var engine: KokoroEngine?
    private var loadedDir: String?

    /// Synthesize `text` from the Kokoro model installed at `modelDir` in the chosen
    /// voice (`speakerId`), loading (and caching) the engine on first use. The speaker
    /// is passed per-call so switching voices never reloads the ~330 MB model. `nil` ⇒
    /// SDK absent or load/synthesis failed.
    func synthesize(_ text: String, modelDir: String, speakerId: Int) -> NeuralSpeech? {
        if loadedDir != modelDir {
            engine = KokoroEngine(modelDir: modelDir)
            loadedDir = engine == nil ? nil : modelDir
        }
        guard let s = engine?.synthesize(text, speakerId: speakerId) else { return nil }
        return NeuralSpeech(samples: KokoroGain().apply(s.samples), sampleRate: s.sampleRate)
    }

    /// Load (and cache) the engine for `modelDir` and return its native sample rate
    /// (Kokoro = 24000), or 0 when the SDK is absent / the model can't load. The streaming
    /// player needs the rate up front to build its buffer format, so this runs before the
    /// first chunk. Idempotent with `warmup`/`synthesize` — only ever loads once.
    func prepare(modelDir: String) -> Double {
        if loadedDir != modelDir {
            engine = KokoroEngine(modelDir: modelDir)
            loadedDir = engine == nil ? nil : modelDir
        }
        return engine?.sampleRate ?? 0
    }

    /// Streaming synthesis: segment `text`, then synthesize segment by segment, forwarding
    /// every chunk to `onChunk` the instant sherpa produces it (so segment N plays while
    /// N+1 synthesizes). `cancel` aborts mid-utterance on barge-in (the chunk callback
    /// returns 0). Returns the number of non-empty chunks emitted — 0 ⇒ produced nothing,
    /// caller should fall back to the non-streaming path.
    func synthesizeStreaming(_ text: String, modelDir: String, speakerId: Int,
                             cancel: KokoroCancelToken,
                             onChunk: @Sendable @escaping (_ chunk: [Float]) -> Bool) -> Int {
        if loadedDir != modelDir {
            engine = KokoroEngine(modelDir: modelDir)
            loadedDir = engine == nil ? nil : modelDir
        }
        guard let engine else { return 0 }
        let gain = KokoroGain()
        return runKokoroStream(
            segments: KokoroSegmenter.segments(text),
            isCancelled: { cancel.isCancelled },
            sink: { chunk in onChunk(gain.apply(chunk)) },
            synthSegment: { seg, emit in engine.synthesizeSegment(seg, speakerId: speakerId, emit: emit) }
        )
    }

    /// Preload the engine (the ~330 MB model) so the first brief doesn't pay the load.
    /// Idempotent: a no-op once the engine for `modelDir` is resident, so repeated calls
    /// — and a warmup racing the first real `synthesize` — only ever load once. Returns
    /// whether a usable engine is loaded.
    @discardableResult
    func warmup(modelDir: String) -> Bool {
        if loadedDir != modelDir {
            engine = KokoroEngine(modelDir: modelDir)
            loadedDir = engine == nil ? nil : modelDir
        }
        return engine != nil
    }

    /// Drop the cached engine (e.g. after the model is deleted) to free memory.
    func unload() { engine = nil; loadedDir = nil }

    /// Give the ~330 MB sherpa engine back when the OS reports memory pressure —
    /// the same guard `LiteRTEngine` has. Without it, one read-aloud pinned the model
    /// for the rest of the process lifetime, including while suspended in the
    /// background, which is the classic jetsam profile. Armed once from the app's
    /// startup task; the handler runs off-actor and hops back in to unload.
    nonisolated static func armMemoryPressureUnload() {
        guard pressureSource == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                          queue: .global(qos: .utility))
        src.setEventHandler {
            Log.engine.error("Kokoro: memory pressure — unloading TTS model")
            Task { await KokoroCache.shared.unload() }
        }
        src.resume()
        pressureSource = src
    }

    private nonisolated(unsafe) static var pressureSource: DispatchSourceMemoryPressure?
}

/// WAV container for raw float PCM, so Kokoro output plays through `AVAudioPlayer`
/// (and the existing amplitude metering) exactly like the OpenAI MP3 path.
enum WAVWriter {
    static func data(samples: [Float], sampleRate: Double) -> Data? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sr = UInt32(sampleRate)
        let byteRate = sr * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count) * UInt32(bitsPerSample / 8)

        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels); u32(sr); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(dataSize)
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            let v = Int16(clamped * Float(Int16.max))
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}

// MARK: - sherpa-onnx engine (compiled only when the SDK is vendored)

#if BRIDGE_KOKORO
// The sherpa-onnx C API is exposed via the bridging header
// (Vendor/swift/SherpaOnnx-Bridging-Header.h); the Swift wrappers used below
// (SherpaOnnxOfflineTtsWrapper, the config factories) live in Vendor/swift/SherpaOnnx.swift,
// compiled into this same module — so there's nothing to import.

/// Kokoro offline TTS over sherpa-onnx. Loads the model files the core manager
/// unpacked into `modelDir` (model.onnx, voices.bin, tokens.txt, espeak-ng-data, …).
final class KokoroEngine {
    private let tts: SherpaOnnxOfflineTtsWrapper

    init?(modelDir: String) {
        let fm = FileManager.default
        let model = "\(modelDir)/model.onnx"
        let voices = "\(modelDir)/voices.bin"
        let tokens = "\(modelDir)/tokens.txt"
        guard fm.fileExists(atPath: model), fm.fileExists(atPath: voices), fm.fileExists(atPath: tokens) else {
            return nil
        }
        let dataDir = "\(modelDir)/espeak-ng-data"
        let dictDir = fm.fileExists(atPath: "\(modelDir)/dict") ? "\(modelDir)/dict" : ""
        let lexicon = [ "lexicon-us-en.txt", "lexicon-zh.txt", "lexicon.txt" ]
            .map { "\(modelDir)/\($0)" }
            .filter { fm.fileExists(atPath: $0) }
            .joined(separator: ",")

        var kokoro = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: model,
            voices: voices,
            tokens: tokens,
            dataDir: dataDir,
            dictDir: dictDir,
            lexicon: lexicon
        )
        var modelConfig = sherpaOnnxOfflineTtsModelConfig(kokoro: kokoro, numThreads: 2)
        var config = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        tts = SherpaOnnxOfflineTtsWrapper(config: &config)
    }

    func synthesize(_ text: String, speakerId: Int) -> NeuralSpeech? {
        let audio = tts.generate(text: text, sid: speakerId, speed: 1.0)
        guard !audio.samples.isEmpty else { return nil }
        return NeuralSpeech(samples: audio.samples, sampleRate: Double(audio.sampleRate))
    }

    /// The model's output sample rate (Kokoro = 24000).
    var sampleRate: Double { Double(SherpaOnnxOfflineTtsSampleRate(tts.tts)) }

    /// Synthesize one segment via sherpa's incremental callback API: `emit` is invoked for
    /// each generated chunk (`maxNumSentences` keeps it sentence-grained), returning false
    /// to abort this segment mid-pass. The chunk samples are copied out before `emit` so
    /// the caller may keep them past the callback's lifetime.
    func synthesizeSegment(_ text: String, speakerId: Int, emit: (_ chunk: [Float]) -> Bool) {
        final class Box { let emit: ([Float]) -> Bool; init(_ e: @escaping ([Float]) -> Bool) { emit = e } }
        withoutActuallyEscaping(emit) { emit in
            let box = Box(emit)
            let unmanaged = Unmanaged.passRetained(box)
            defer { unmanaged.release() }
            let cb: TtsCallbackWithArg = { samplesPtr, n, arg in
                let box = Unmanaged<Box>.fromOpaque(arg!).takeUnretainedValue()
                let count = Int(n)
                let chunk = (count > 0 && samplesPtr != nil)
                    ? Array(UnsafeBufferPointer(start: samplesPtr, count: count))
                    : []
                return box.emit(chunk) ? 1 : 0
            }
            _ = tts.generateWithCallbackWithArg(text: text, callback: cb, arg: unmanaged.toOpaque(),
                                                sid: speakerId, speed: 1.0)
        }
    }
}

#else

/// Placeholder when sherpa-onnx isn't linked — keeps `KokoroCache` compiling and the
/// free TTS lane gracefully falling back to the Apple voice.
final class KokoroEngine {
    init?(modelDir: String) { return nil }
    func synthesize(_ text: String, speakerId: Int) -> NeuralSpeech? { nil }
    var sampleRate: Double { 0 }
    func synthesizeSegment(_ text: String, speakerId: Int, emit: (_ chunk: [Float]) -> Bool) {}
}

#endif
