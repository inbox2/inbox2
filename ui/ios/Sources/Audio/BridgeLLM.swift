import Foundation
import os

/// Process-wide foreground flag, set from the app's `scenePhase`. On-device model
/// LOADS are gated on it: a backgrounded app has a tiny jetsam budget, and cold-loading
/// a 0.7–1.6 GB LiteRT model there is a near-certain kill — confirmed in the field, where
/// Inbox2 was repeatedly the largest process on the device when jettisoned *while
/// suspended*, holding 0.8–1.8 GB. Read on the triage worker's background queue, so the
/// access is lock-guarded.
enum AppActivity {
    private static let state = OSAllocatedUnfairLock(initialState: true)
    static var isForeground: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// The on-device generator the Rust core's Bridge calls (`OnDeviceLlm` callback) for
/// brief/reply writing when generation is routed on-device. It **routes between two
/// engines** by the user's NLU lane preference:
///   - `native` → Apple Foundation Models (`AppleLLM`, iOS 26+, AI hardware).
///   - `free`   → a downloaded small LLM via LiteRT/MediaPipe — the user's variant
///     choice: the smaller/faster Gemma 3 1B (default) or Qwen2.5 1.5B Instruct.
/// Either way, OpenAI generation is handled in-Rust and never reaches here. Falls back
/// to Apple (then the core's deterministic text) if the chosen engine isn't usable.
final class BridgeLLM: OnDeviceLlm {
    private let apple = AppleLLM()
    private let dataDir: URL

    init(dataDir: URL) { self.dataDir = dataDir }

    func isAvailable() -> Bool {
        // Apple FM is a system model (no app-memory cost) — fine to use backgrounded.
        if apple.isAvailable() { return true }
        // The free LiteRT lane cold-loads a ~1 GB model. Don't advertise it while
        // backgrounded: the core's triage worker keys off this, so reporting it
        // unavailable makes ambiguous threads DEFER (reactivated on foreground) or
        // route to OpenAI — instead of forcing a load that gets the suspended app
        // jettisoned. Deterministic categories need no model and still process.
        if !AppActivity.isForeground { return false }
        return liteRTUsable()
    }

    func generate(system: String, user: String, model: String?) throws -> String {
        do {
            // Forced engine (the core's per-call hint — `onDeviceModel` from the
            // config: the resolved pref for background triage, or an explicit
            // choice for the reader's "Process with"). Honor it when runnable;
            // a missing/failed hint falls through to the preference route.
            if let model, model != BridgeModelIDs.appleFM,
               let path = installedModelPath(model) {
                if let text = try? LiteRTEngine.shared.generate(system: system, user: user, modelPath: path),
                   !text.isEmpty {
                    return text
                }
                Log.engine.error("forced model \(model, privacy: .public) returned empty/failed; falling back")
            }
            if model == BridgeModelIDs.appleFM {
                return try apple.generate(system: system, user: user, model: nil)
            }
            // Free lane: try the downloaded model first; fall through to Apple.
            if let path = freeRouteOrLog() {
                if let text = try? LiteRTEngine.shared.generate(system: system, user: user, modelPath: path),
                   !text.isEmpty {
                    return text
                }
                Log.engine.error("free-lane generate returned empty/failed; falling back to Apple FM")
            }
            return try apple.generate(system: system, user: user, model: nil)
        } catch {
            // The core's `OnDeviceLlm` callback may only throw the bridged `FfiError`;
            // any other error type (e.g. a FoundationModels `GenerationError` when Apple
            // Intelligence is off — `isAvailable()` is intentionally optimistic) would
            // crash the UniFFI callback boundary instead of returning an error. Convert
            // it so the core fails soft to its deterministic fallback text.
            throw FfiError.Engine(String(describing: error))
        }
    }

    /// Classify a command into the Bridge intent schema. Apple Foundation Models uses
    /// guided generation (guaranteed schema-valid); the free lane runs the plain
    /// text-JSON prompt, which the core's tolerant parser handles.
    func generateIntent(system: String, user: String, model: String?) throws -> String {
        do {
            if let model, model != BridgeModelIDs.appleFM,
               let path = installedModelPath(model) {
                if let text = try? LiteRTEngine.shared.generate(system: system, user: user, modelPath: path),
                   !text.isEmpty {
                    return text
                }
                Log.engine.error("forced model \(model, privacy: .public) intent returned empty/failed; falling back")
            }
            if model == BridgeModelIDs.appleFM {
                return try apple.generateIntent(system: system, user: user, model: nil)
            }
            if let path = freeRouteOrLog() {
                if let text = try? LiteRTEngine.shared.generate(system: system, user: user, modelPath: path),
                   !text.isEmpty {
                    return text
                }
                Log.engine.error("free-lane intent returned empty/failed; falling back to Apple FM")
            }
            return try apple.generateIntent(system: system, user: user, model: nil)
        } catch {
            throw FfiError.Engine(String(describing: error))
        }
    }

    /// Resolve the free-lane model path, or log exactly why we're falling back to
    /// Apple FM — the decisive diagnostic for "I picked the free model but it's using
    /// Apple". The three failure modes: lane isn't `free`, MediaPipe/LiteRT isn't
    /// linked (`liteRT=false`), or no variant is on disk where we look (`model=nil`).
    private func freeRouteOrLog() -> String? {
        let pref = nluPref()
        let path = freeModelPath()
        if pref == .free, let path { return path }
        Log.engine.info("on-device → Apple FM (nlu=\(pref.rawValue, privacy: .public) liteRTLinked=\(LiteRTEngine.isAvailable, privacy: .public) modelPath=\(path ?? "nil", privacy: .public))")
        return nil
    }

    /// The persisted NLU lane preference (mirrors `VoiceEngineManager`).
    private func nluPref() -> BridgeLane {
        BridgeLane(rawValue: UserDefaults.standard.string(forKey: "inbox2_voice_lane_nlu") ?? "") ?? .native
    }

    /// The free-lane model to run: the user's variant choice (Gemma default / Qwen),
    /// falling back to the other variant when the chosen one isn't installed — so
    /// deleting one model never silently kills the lane while the other is on disk.
    private func freeModelPath() -> String? {
        let chosen = UserDefaults.standard.string(forKey: VoiceEngineManager.freeNluModelKey) ?? BridgeModelIDs.gemma
        let other = chosen == BridgeModelIDs.qwen ? BridgeModelIDs.gemma : BridgeModelIDs.qwen
        return installedModelPath(chosen) ?? installedModelPath(other)
    }

    /// The installed `.task` model path for a manifest id, or nil if not fully
    /// downloaded / the LiteRT engine isn't linked.
    private func installedModelPath(_ id: String) -> String? {
        guard LiteRTEngine.isAvailable else { return nil }
        let dir = dataDir.appendingPathComponent("models/\(id)", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(".complete").path),
              let files = try? fm.contentsOfDirectory(atPath: dir.path),
              let model = files.first(where: { $0.hasSuffix(".task") || $0.hasSuffix(".bin") })
        else { return nil }
        return dir.appendingPathComponent(model).path
    }

    private func liteRTUsable() -> Bool {
        nluPref() == .free && freeModelPath() != nil
    }
}

// MARK: - LiteRT / MediaPipe engine (compiled only when the SDK is linked)

#if canImport(MediaPipeTasksGenAI)
import MediaPipeTasksGenAI
import os

/// Free-lane (LiteRT) text generation via MediaPipe — runs whichever `.task` it's
/// handed (Qwen or Gemma; the turn format follows the model). The `LlmInference` is
/// cached (load is expensive) and calls are serialized — the core invokes `generate`
/// from its runtime threads. Synchronous, matching the `OnDeviceLlm` contract.
final class LiteRTEngine {
    static let shared = LiteRTEngine()
    static var isAvailable: Bool { true }

    /// Hard cap on a single load+inference *wait*. A genuine triage/brief generation
    /// finishes well under this; the cap exists because MediaPipe's `generateResponse`
    /// is synchronous and non-cancellable, so a deadlocked or runaway call would
    /// otherwise wedge the core's single background triage worker forever (it drains
    /// one job at a time and can't reclaim a stuck one until the call returns). The
    /// first call after (re)download blows through this legitimately — it builds the
    /// ~model-sized weight cache — and keeps running behind `gate` while the caller
    /// falls back; once the build lands, later calls are fast.
    private static let timeout: DispatchTimeInterval = .seconds(90)

    private let lock = NSLock()
    private var llm: LlmInference?
    private var loadedPath: String?
    /// Unloads the resident model when the OS reports memory pressure, so we give the
    /// ~1 GB back before the kernel jettisons us for it.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private init() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                          queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in
            Log.engine.error("LiteRT: memory pressure — unloading on-device model")
            self?.unload()
        }
        src.resume()
        memoryPressureSource = src
    }

    /// Drop the resident model so a backgrounded / under-pressure process isn't holding
    /// ~1 GB (the dominant jetsam trigger in the field). Safe during an in-flight
    /// generation: that call captured its own strong `LlmInference` ref, so ARC keeps
    /// the live engine alive until it finishes; we only clear the shared cache so the
    /// next call rebuilds — which the foreground gate below limits to when we're active.
    func unload() {
        lock.lock(); defer { lock.unlock() }
        guard llm != nil else { return }
        llm = nil
        loadedPath = nil
        Log.engine.info("LiteRT: unloaded on-device model")
    }
    /// Single-flight for the WHOLE load+inference. Field SIGBUS crashes: when a call
    /// outlived its caller's timeout and a second `LlmInference` was built over the
    /// same weight cache, MediaPipe re-opened the (unfinalized) cache for building and
    /// truncated the file the first engine still had mmap'd — its inference threads
    /// then died reading unmapped pages. Only the worker that holds the gate may touch
    /// the engine or the cache, and it releases the gate only when the call has truly
    /// finished — a wedged call keeps the lane failing soft instead of crashing.
    private let gate = DispatchSemaphore(value: 1)

    func generate(system: String, user: String, modelPath: String) throws -> String {
        // Per-model chat format, mirrored on Android (the desktop sidecar needs
        // neither: llama-server applies the GGUF-embedded template). The `.task`
        // bundles bake in the stop token but NOT the turn markers, so wrap turns
        // ourselves; raw concatenated text degrades output quality badly.
        //   - Qwen: ChatML (<|im_start|>…<|im_end|>), with a real system turn.
        //   - Gemma: <start_of_turn> markers; no system role — fold it into the
        //     user turn.
        let prompt: String
        if modelPath.contains(BridgeModelIDs.gemma) {
            let content = system.isEmpty ? user : "\(system)\n\n\(user)"
            prompt = "<start_of_turn>user\n\(content)<end_of_turn>\n<start_of_turn>model\n"
        } else {
            prompt = system.isEmpty
                ? "<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
                : "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        }
        // Don't COLD-LOAD a 0.7–1.6 GB model while backgrounded — the jetsam budget is
        // tiny there and the process is the OS's first victim. A warm engine keeps
        // serving (e.g. a generation already in flight when we backgrounded); only a
        // load is refused, degrading to Apple FM / the core's deterministic fallback.
        if needsEngineBuild(modelPath) && !AppActivity.isForeground {
            throw NSError(domain: "LiteRT", code: -7, userInfo: [NSLocalizedDescriptionKey:
                "on-device model load deferred: app is backgrounded"])
        }
        guard gate.wait(timeout: .now() + .seconds(2)) == .success else {
            throw NSError(domain: "LiteRT", code: -5, userInfo: [NSLocalizedDescriptionKey:
                "a previous on-device generation is still running (likely the first-load cache build)"])
        }
        // Run load + inference off the calling thread so a hang can't block the worker
        // past the timeout. The orphaned work (if it ever returns) just signals a
        // semaphore nobody is waiting on — and releases the gate.
        var outcome: Result<String, Error>?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            // Ask iOS for time to finish if we're backgrounded mid-call. Without it the
            // process freezes inside generateResponse and this call's strong engine ref
            // keeps the model resident all through suspension, which `unload()` can't
            // reach. ponytail: MediaPipe can't be cancelled, so a call outliving the
            // ~30 s grant still freezes holding the model.
            let keepAwake = DispatchSemaphore(value: 0)
            ProcessInfo.processInfo.performExpiringActivity(withReason: "on-device generation") { expired in
                if expired { keepAwake.signal() } else { keepAwake.wait() }
            }
            defer { keepAwake.signal() }
            do {
                // Arms the crash marker; disarmed below on every non-crash exit, so a
                // surviving marker means the process died inside load OR inference.
                try Self.preflight(modelPath: modelPath, buildingEngine: self.needsEngineBuild(modelPath))
                let engine = try self.engine(for: modelPath)
                // A fresh session per call: independent context (no cross-call
                // accumulation) and explicit sampling — read over the FFI from the
                // core's shared free-lane constants (`bridge::ON_DEVICE_*`) so the
                // same input scores the same on desktop's sidecar and Android.
                let sessionOptions = LlmInference.Session.Options()
                sessionOptions.temperature = onDeviceTemperature()
                sessionOptions.topk = Int(onDeviceTopK())
                let session = try LlmInference.Session(llmInference: engine, options: sessionOptions)
                try session.addQueryChunk(inputText: prompt)
                let text = try session.generateResponse()
                outcome = .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                outcome = .failure(error)
            }
            try? FileManager.default.removeItem(atPath: Self.markerPath(modelPath))
            self.gate.signal()
            done.signal()
        }
        if done.wait(timeout: .now() + Self.timeout) == .timedOut {
            // Do NOT touch the engine here: the call is still running and still owns
            // the gate (and the weight-cache mmap). It finishes or wedges on its own;
            // either way the gate keeps the next call from doubling up on the cache.
            throw NSError(domain: "LiteRT", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "on-device generation timed out"])
        }
        return try outcome!.get()
    }

    /// Get or (re)build the cached inference for `modelPath`. The lock guards only the
    /// shared `llm`/`loadedPath` state — never the inference call itself — so a slow
    /// generation never blocks the next one's setup.
    private func needsEngineBuild(_ modelPath: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return llm == nil || loadedPath != modelPath
    }

    private func engine(for modelPath: String) throws -> LlmInference {
        lock.lock(); defer { lock.unlock() }
        if loadedPath != modelPath || llm == nil {
            // Drop the old engine BEFORE building the new one. On a variant switch
            // (Qwen ↔ Gemma) the two engines — weights plus a ~250 MB KV cache each —
            // otherwise coexist for the whole build, enough to blow the jetsam budget
            // on its own (field SIGSEGVs 2026-06-11, null KV-cache alloc at create).
            llm = nil
            loadedPath = nil
            let options = LlmInference.Options(modelPath: modelPath)
            // Total token budget (input + output) — the core's shared
            // ON_DEVICE_CONTEXT_TOKENS over the FFI: matches the ekv4096 KV cache
            // of both .task bundles (Qwen + Gemma) and the desktop sidecar's
            // --ctx-size. The triage prompt plus a direction-tagged 8-message
            // thread needs well over the old 1024.
            options.maxTokens = Int(onDeviceContextTokens())
            llm = try LlmInference(options: options)
            loadedPath = modelPath
        }
        return llm!
    }

    /// MediaPipe builds an XNNPACK weight cache (~the model's size) next to the
    /// `.task` on first load, and cache trouble kills the process in ways Swift cannot
    /// catch (C++ `abort()` during build, SIGBUS reading a clobbered mmap during
    /// inference) — both crash-looped the app in the field (the triage worker loads
    /// the model right away). Two uncatchables we CAN see coming:
    ///   - a previous call died mid-load or mid-inference, leaving a cache of unknown
    ///     integrity → a marker file is armed for the whole call (disarmed on every
    ///     non-crash exit); when it survives, delete the cache and rebuild;
    ///   - the volume can't hold the rest of the cache → check before loading;
    ///   - the jetsam budget can't hold the engine → check before loading. Executor
    ///     create allocates the ekv4096 KV cache (~250 MB of dirty float32) with an
    ///     allocator that returns null on failure, and LiteRT dereferences it
    ///     unchecked — the process dies at 0x0 (field SIGSEGVs 2026-06-11).
    /// After two consecutive crashed calls the lane is disabled (throws) until the
    /// model is re-downloaded — a thrown error degrades to Apple FM / the core's
    /// fallback text, a crash takes the whole app down.
    private static func preflight(modelPath: String, buildingEngine: Bool) throws {
        let fm = FileManager.default
        let marker = markerPath(modelPath)
        let cache = modelPath + ".xnnpack_cache"

        var priorCrashes = 0
        if fm.fileExists(atPath: marker) {
            priorCrashes = (try? String(contentsOfFile: marker, encoding: .utf8))
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
            try? fm.removeItem(atPath: cache)
            Log.engine.error("LiteRT: previous model load/inference crashed (\(priorCrashes, privacy: .public)×); dropped weight cache")
        }
        guard priorCrashes < 2 else {
            throw NSError(domain: "LiteRT", code: -3, userInfo: [NSLocalizedDescriptionKey:
                "model crashed \(priorCrashes)× in a row; lane disabled until the model is re-downloaded"])
        }

        let modelSize = ((try? fm.attributesOfItem(atPath: modelPath))?[.size] as? Int64) ?? 0
        let cacheSize = ((try? fm.attributesOfItem(atPath: cache))?[.size] as? Int64) ?? 0
        let needed = max(0, modelSize - cacheSize) + 256 << 20
        let available = (try? URL(fileURLWithPath: modelPath)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? .max
        guard available >= needed else {
            throw NSError(domain: "LiteRT", code: -4, userInfo: [NSLocalizedDescriptionKey:
                "not enough free space to build the weight cache (need ~\(needed >> 20) MB, have \(available >> 20) MB)"])
        }

        // RAM: building an engine dirties the KV cache + executor scratch (weights
        // come off the mmap'd cache when one exists; a cache build holds ~the model
        // dirty too). A warm engine only needs inference scratch. 0 = budget unknown
        // (not an app process) — skip rather than block.
        let cacheBuilt = cacheSize >= modelSize / 2
        let ramNeeded = buildingEngine
            ? (cacheBuilt ? 0 : modelSize) + (512 << 20)
            : 128 << 20
        let ramAvailable = Int64(os_proc_available_memory())
        guard ramAvailable == 0 || ramAvailable >= ramNeeded else {
            throw NSError(domain: "LiteRT", code: -6, userInfo: [NSLocalizedDescriptionKey:
                "not enough memory to run the model (need ~\(ramNeeded >> 20) MB, have \(ramAvailable >> 20) MB)"])
        }

        try "\(priorCrashes + 1)".write(toFile: marker, atomically: true, encoding: .utf8)
    }

    private static func markerPath(_ modelPath: String) -> String { modelPath + ".loading" }
}

#else

/// Placeholder when MediaPipe/LiteRT isn't linked — keeps `BridgeLLM` compiling; the
/// free NLU lane then resolves to Apple Foundation Models.
final class LiteRTEngine {
    static let shared = LiteRTEngine()
    static var isAvailable: Bool { false }
    func generate(system: String, user: String, modelPath: String) throws -> String {
        throw NSError(domain: "LiteRT", code: -1, userInfo: [NSLocalizedDescriptionKey: "LiteRT not linked"])
    }
    func unload() {}
}

#endif
