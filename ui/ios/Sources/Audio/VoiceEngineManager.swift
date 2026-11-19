import SwiftUI
import AVFoundation

/// Which lane a Bridge capability runs in. Three lanes, one source of truth in the
/// Rust core (`bridge/models`): `native` = the OS engine (free, private, hidden where
/// the device can't do it), `free` = a downloaded best-in-class open model, `openai`
/// = the user's own API key (better, paid, leaves the device).
enum BridgeLane: String, CaseIterable, Identifiable {
    case native, free, openai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "On-device"
        case .free: return "Best free"
        case .openai: return "OpenAI"
        }
    }
}

/// A configurable Bridge capability. `rawValue` matches the core capability string
/// (`tts`/`stt`/`nlu`) passed across the FFI.
enum BridgeCapability: String, CaseIterable, Identifiable {
    case stt, tts, nlu
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stt: return "Voice input"
        case .tts: return "Voice output"
        case .nlu: return "Brief writing"
        }
    }
    var subtitle: String {
        switch self {
        case .stt: return "Speech-to-text when you hold the orb."
        case .tts: return "The spoken voice of the Bridge."
        case .nlu: return "Writes your daily brief and replies."
        }
    }
    var icon: String {
        switch self {
        case .stt: return "mic"
        case .tts: return "speaker.wave.2"
        case .nlu: return "text.alignleft"
        }
    }
    /// First-run default lane — mirrors the core `default_pref`: TTS defaults to the
    /// (downloadable) free Kokoro voice since native voices are robotic; STT/NLU
    /// default to native where available.
    var defaultLane: BridgeLane { self == .tts ? .free : .native }
}

/// A selectable OpenAI tts-1 voice. `id` is the API voice name passed across the FFI.
struct OpenAIVoice: Identifiable, Hashable {
    let id: String
    let descriptor: String
    var name: String { id.prefix(1).uppercased() + id.dropFirst() }
    var label: String { "\(name) · \(descriptor)" }

    static let defaultId = "alloy"

    static let catalog: [OpenAIVoice] = [
        .init(id: "alloy",   descriptor: "neutral"),
        .init(id: "nova",    descriptor: "US · female"),
        .init(id: "shimmer", descriptor: "US · female, soft"),
        .init(id: "fable",   descriptor: "UK · expressive"),
        .init(id: "echo",    descriptor: "US · male"),
        .init(id: "onyx",    descriptor: "US · deep male"),
    ]

    static func named(_ id: String) -> OpenAIVoice {
        catalog.first { $0.id == id } ?? catalog[0]
    }
}

/// Persists the Bridge voice configuration: an OpenAI API key (optional) and a
/// per-capability lane preference for speech-in (STT), speech-out (TTS), and brief
/// writing (NLU). The lane that actually *runs* is resolved by the core
/// (`InboxEngine.effectiveLane`) from this preference + device support + whether the
/// free model is downloaded + key validity — so an unavailable choice degrades
/// gracefully. Mirrors the MarkReadManager / ThemeManager persistence pattern;
/// injected via the environment.
/// Which TTS surface is speaking — the Bridge dialog (briefs, command replies) or the
/// read-aloud reader (triage summaries). The reader can override each lane's voice
/// (e.g. Nicole for the Bridge, a brisker voice for summaries); unset overrides
/// follow the Bridge choice.
enum VoiceSurface {
    case bridge, reader
}

@MainActor
final class VoiceEngineManager: ObservableObject {
    @Published var sttPref: BridgeLane { didSet { Self.persist(.stt, sttPref) } }
    @Published var ttsPref: BridgeLane { didSet { Self.persist(.tts, ttsPref) } }
    @Published var nluPref: BridgeLane { didSet { Self.persist(.nlu, nluPref) } }

    /// Car mode = the full daily brief (hands-free); off ("normal") = a terse spoken
    /// headline. The DEFAULT follows the Bluetooth-audio connection: connected (car
    /// kit/headset) → on, disconnected → off. `bluetoothConnected` tracks the live
    /// audio route; not persisted.
    @Published private(set) var bluetoothConnected: Bool = false

    /// Manual override of car mode for the current connection (`nil` = follow Bluetooth).
    /// Reset to `nil` whenever the Bluetooth connection flips, so each drive starts from
    /// the Bluetooth-driven default while still letting the user flip it for the session.
    @Published var carModeOverride: Bool?

    /// True while connected to a CarPlay head unit (set by the CarPlay scene; Phase 2).
    @Published var carPlayConnected: Bool = false

    /// The brief verbosity that actually applies: CarPlay forces the full brief; else a
    /// manual override if set, else whether Bluetooth audio is connected.
    var effectiveCarMode: Bool { carPlayConnected || (carModeOverride ?? bluetoothConnected) }

    /// Flip car mode for the current connection (the top-left Bridge toggle).
    func toggleCarMode() { carModeOverride = !effectiveCarMode }

    /// Token for the audio-route-change observer driving `bluetoothConnected`.
    private var routeObserver: NSObjectProtocol?

    /// The free NLU lane's model variant (manifest id): Gemma (default on iPhone —
    /// smaller and faster to load) or Qwen (best quality, multilingual, but its
    /// 1.6 GB `.task` loads and generates noticeably slower here).
    /// `BridgeLLM` reads the same key at generate time to pick the engine file.
    @Published var freeNluModel: String { didSet { UserDefaults.standard.set(freeNluModel, forKey: Self.freeNluModelKey) } }

    /// The chosen Kokoro speaker id (the free TTS lane's voice). Defaults to af_heart.
    @Published var kokoroVoiceId: Int { didSet { UserDefaults.standard.set(kokoroVoiceId, forKey: Self.kokoroVoiceKey) } }
    /// The chosen OpenAI tts-1 voice (the OpenAI TTS lane). Defaults to alloy.
    @Published var openAIVoice: String { didSet { UserDefaults.standard.set(openAIVoice, forKey: Self.openAIVoiceKey) } }
    /// The chosen Apple on-device voice identifier (the native TTS lane). "" = Automatic
    /// (best installed per language — the multilingual/international default).
    @Published var appleVoiceId: String { didSet { UserDefaults.standard.set(appleVoiceId, forKey: Self.appleVoiceKey) } }

    /// Read-aloud (summaries) voice overrides, one per lane — `nil` = same as the
    /// Bridge voice. Resolved through `kokoroVoiceId(for:)` & co.
    @Published var readerKokoroVoiceId: Int? { didSet { Self.persistOptional(readerKokoroVoiceId, key: Self.readerKokoroVoiceKey) } }
    @Published var readerOpenAIVoice: String? { didSet { Self.persistOptional(readerOpenAIVoice, key: Self.readerOpenAIVoiceKey) } }
    @Published var readerAppleVoiceId: String? { didSet { Self.persistOptional(readerAppleVoiceId, key: Self.readerAppleVoiceKey) } }

    /// The OpenAI key — stored in the Keychain (encrypted), not UserDefaults. Editing
    /// it always invalidates a prior successful test.
    @Published var openAIKey: String {
        didSet {
            // didSet fires on every assignment, even when the value is unchanged.
            // SwiftUI's SecureField re-emits its text into this binding on re-renders
            // and focus changes; without this guard each no-op write would wipe a
            // prior successful test (keyValidated) and rewrite the Keychain. Only act
            // when the key has actually changed.
            guard openAIKey != oldValue else { return }
            if openAIKey.isEmpty { Keychain.delete(Self.keyAccount) } else { Keychain.set(openAIKey, for: Self.keyAccount) }
            keyValidated = false
        }
    }
    /// True only after "Test & save" succeeds. Gates all OpenAI usage; persists across
    /// restarts (it's not a secret, so UserDefaults is fine).
    @Published var keyValidated: Bool { didSet { UserDefaults.standard.set(keyValidated, forKey: Self.validKey) } }

    private static let keyAccount = "openai_api_key"
    private static let validKey = "inbox2_openai_key_valid"
    private static let kokoroVoiceKey = "inbox2_kokoro_voice_id"
    static let freeNluModelKey = "inbox2_nlu_free_model"
    private static let openAIVoiceKey = "inbox2_openai_voice"
    private static let appleVoiceKey = "inbox2_apple_voice"
    private static let readerKokoroVoiceKey = "inbox2_reader_kokoro_voice_id"
    private static let readerOpenAIVoiceKey = "inbox2_reader_openai_voice"
    private static let readerAppleVoiceKey = "inbox2_reader_apple_voice"
    /// Per-capability lane key, e.g. `inbox2_voice_lane_tts`.
    private static func laneKey(_ cap: BridgeCapability) -> String { "inbox2_voice_lane_\(cap.rawValue)" }

    init() {
        // didSet does not fire during init, so keyValidated survives loading the key.
        sttPref = Self.loadPref(.stt)
        ttsPref = Self.loadPref(.tts)
        nluPref = Self.loadPref(.nlu)
        freeNluModel = UserDefaults.standard.string(forKey: Self.freeNluModelKey) ?? BridgeModelIDs.gemma
        openAIKey = Keychain.get(Self.keyAccount) ?? ""
        keyValidated = UserDefaults.standard.bool(forKey: Self.validKey)
        // object(forKey:) distinguishes "never set" from a stored 0.
        kokoroVoiceId = UserDefaults.standard.object(forKey: Self.kokoroVoiceKey) as? Int ?? KokoroVoice.defaultId
        openAIVoice = UserDefaults.standard.string(forKey: Self.openAIVoiceKey) ?? OpenAIVoice.defaultId
        appleVoiceId = UserDefaults.standard.string(forKey: Self.appleVoiceKey) ?? ""
        readerKokoroVoiceId = UserDefaults.standard.object(forKey: Self.readerKokoroVoiceKey) as? Int
        readerOpenAIVoice = UserDefaults.standard.string(forKey: Self.readerOpenAIVoiceKey)
        readerAppleVoiceId = UserDefaults.standard.string(forKey: Self.readerAppleVoiceKey)
        // The free STT lane (WhisperKit) is gone — SpeechAnalyzer covers it on-device.
        // A stored `free` preference from an older build resolves to native.
        if sttPref == .free { sttPref = .native }
        // Car mode defaults to the Bluetooth-audio connection: seed it now, then track
        // route changes so connecting/disconnecting a car kit flips the default live.
        refreshBluetooth()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees the main thread; hop onto the actor to mutate state.
            Task { @MainActor in self?.refreshBluetooth() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// Recompute `bluetoothConnected` from the current audio output route. When it flips,
    /// clear any manual override so the Bluetooth-driven default takes over again.
    private func refreshBluetooth() {
        let btPorts: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .carAudio]
        let connected = AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { btPorts.contains($0.portType) }
        guard connected != bluetoothConnected else { return }
        bluetoothConnected = connected
        carModeOverride = nil
    }

    /// The lane voices resolved per surface — the reader falls back to the Bridge
    /// choice when it has no override.
    func kokoroVoiceId(for surface: VoiceSurface) -> Int {
        surface == .reader ? (readerKokoroVoiceId ?? kokoroVoiceId) : kokoroVoiceId
    }
    func openAIVoice(for surface: VoiceSurface) -> String {
        surface == .reader ? (readerOpenAIVoice ?? openAIVoice) : openAIVoice
    }
    func appleVoiceId(for surface: VoiceSurface) -> String {
        surface == .reader ? (readerAppleVoiceId ?? appleVoiceId) : appleVoiceId
    }

    private static func persistOptional(_ value: Any?, key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Load a capability's stored lane preference, or the capability default.
    private static func loadPref(_ cap: BridgeCapability) -> BridgeLane {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: laneKey(cap)), let lane = BridgeLane(rawValue: raw) {
            return lane
        }
        return cap.defaultLane
    }

    private static func persist(_ cap: BridgeCapability, _ lane: BridgeLane) {
        UserDefaults.standard.set(lane.rawValue, forKey: laneKey(cap))
    }

    func pref(_ cap: BridgeCapability) -> BridgeLane {
        switch cap {
        case .stt: return sttPref
        case .tts: return ttsPref
        case .nlu: return nluPref
        }
    }

    func setPref(_ cap: BridgeCapability, _ lane: BridgeLane) {
        switch cap {
        case .stt: sttPref = lane
        case .tts: ttsPref = lane
        case .nlu: nluPref = lane
        }
    }

    /// Clear the key + its validation (Settings "Remove key").
    func removeKey() { openAIKey = "" }   // didSet clears the Keychain + resets keyValidated

    var hasKey: Bool { !openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// A stored key enables the OpenAI lane — the key is saved (Keychain) the moment
    /// it's entered and survives restarts, so there's no separate "activate" step.
    /// `keyValidated` is just an optional "we tested it" confidence flag for the UI;
    /// a bad key degrades gracefully (the Bridge speaks/surfaces the OpenAI error).
    var canUseOpenAI: Bool { hasKey }

    /// The AI generation lane to use for NLU — both the Bridge's spoken turns and
    /// the background triage worker. Single source so both stay in lockstep. NLU
    /// runs on OpenAI only when the user picked that lane and a key is present;
    /// otherwise on-device (Apple Foundation Models / the free LLM lane).
    /// `concise` (default false) requests the terse headline brief — set it only on the
    /// daily-brief call from non-car mode. `weather` (default nil) is the short line the
    /// core appends to a morning brief. Both are ignored by every non-brief Bridge call
    /// and by the background triage worker, so the shared config stays unchanged for them.
    func bridgeConfig(engine: EngineModel, concise: Bool = false, weather: String? = nil) -> FfiBridgeConfig {
        let useOpenAI = nluPref == .openai && canUseOpenAI
        return FfiBridgeConfig(
            generation: useOpenAI ? "openai" : "apple",
            openaiKey: openAIKey.isEmpty ? nil : openAIKey,
            model: nil,
            // The engine BridgeLLM will actually run — handed back per call as the
            // forced-model hint and recorded as triage provenance (triage_source).
            onDeviceModel: useOpenAI ? nil : resolvedOnDeviceModel(engine: engine),
            concise: concise,
            weather: weather
        )
    }

    /// The on-device engine the current preference resolves to: Apple FM for the
    /// native lane; for the free lane the chosen variant when installed, else the
    /// other installed variant (BridgeLLM's fallback order), else Apple FM (nothing
    /// installed — BridgeLLM degrades there). Mirrors `BridgeLLM.freeModelPath` so
    /// the recorded provenance matches what actually runs.
    func resolvedOnDeviceModel(engine: EngineModel) -> String {
        guard nluPref == .free else { return BridgeModelIDs.appleFM }
        let other = freeNluModel == BridgeModelIDs.qwen ? BridgeModelIDs.gemma : BridgeModelIDs.qwen
        if engine.modelPath(freeNluModel) != nil { return freeNluModel }
        if engine.modelPath(other) != nil { return other }
        return BridgeModelIDs.appleFM
    }
}
