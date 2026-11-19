package com.inbox2.app.engine

import android.content.Context
import android.util.Log
import uniffi.inbox2_core.OnDeviceLlm

/**
 * On-device text generation for the Bridge (iOS BridgeLLM → here). The shared Rust core
 * calls this for on-device ("apple"/free generation) Bridge turns; on Android there is
 * no native LLM lane, so the free lane *is* the on-device path = LiteRT (MediaPipe),
 * running the user's variant choice: Qwen2.5 1.5B (default) or the smaller/faster
 * Gemma 3 1B, whose `.task` models the shared model manager downloads into
 * `model_path(<id>)`.
 *
 * The LiteRT runtime (`com.google.mediapipe:tasks-genai`) is a large native dependency,
 * so it's behind a runtime check: `isAvailable()` returns true only once both the model
 * is on disk AND the runtime is present, and `generate()` runs the session. Until the
 * MediaPipe dependency is added (see docs/Android-App.md), this reports unavailable and
 * the core falls back to the OpenAI lane — exactly the iOS fallback contract.
 */
class BridgeLLM(private val context: Context, private val engine: () -> EngineModel?) : OnDeviceLlm {

    private val runtime = LiteRtEngine(context)
    private val prefs by lazy { VoicePrefs(context) }

    /** The downloaded `.task` file for a manifest id, if present. */
    private fun taskFile(id: String): java.io.File? {
        val dir = engine()?.modelPath(id)?.let { java.io.File(it) } ?: return null
        if (!dir.exists()) return null
        return dir.walkTopDown().firstOrNull { it.isFile && it.extension == "task" } ?: dir.listFiles()?.firstOrNull { it.isFile }
    }

    /**
     * The free-lane model to run: the chosen variant (Qwen default / Gemma), falling
     * back to the other installed variant — deleting one model never silently kills
     * the lane while the other is on disk. Mirrors iOS BridgeLLM.freeModelPath().
     */
    private fun modelFile(): java.io.File? {
        val chosen = prefs.freeNluModel
        val other = if (chosen == BridgeModelIds.QWEN) BridgeModelIds.GEMMA else BridgeModelIds.QWEN
        return taskFile(chosen) ?: taskFile(other)
    }

    override fun isAvailable(): Boolean = modelFile() != null

    override fun generate(system: String, user: String, model: String?): String {
        // `model` is the core's per-call engine hint (`onDeviceModel` — the resolved
        // pref for background triage, or a forced choice for "Process with"). Honor
        // it when that model is on disk; otherwise resolve as usual.
        val file = model?.let { taskFile(it) } ?: modelFile()
            ?: throw RuntimeException("free-lane model not downloaded")
        return try {
            runtime.generate(file.absolutePath, system, user)
        } catch (e: Throwable) {
            Log.e("com.inbox2.engine", "LiteRT generate failed: ${e.message}")
            throw RuntimeException(e.message ?: "generation failed")
        }
    }

    // Intent classification runs the same plain text-JSON generation on Android —
    // guided generation is an Apple Foundation Models feature; the core's tolerant
    // parser handles the text-JSON reply (iOS BridgeLLM's non-Apple path).
    override fun generateIntent(system: String, user: String, model: String?): String =
        generate(system, user, model)

    /** Free the resident on-device model — called on app background / memory pressure
     *  so the large (~1.6 GB-class) LiteRT engine can't get the suspended process
     *  OOM-killed (iOS BridgeLLM background-unload parity). No-op while a generation
     *  is in flight (it owns the engine + weight-cache mmap). */
    fun unloadModel() = runtime.unload()
}

/** Shared model ids (mirrors iOS BridgeModelIDs / the core manifest). */
object BridgeModelIds {
    const val KOKORO = "kokoro-multi-lang-v1"
    const val QWEN = "qwen2.5-1.5b-instruct-q8"
    /** The free NLU lane's alternate — ~2x smaller/faster, English-only, gated repo. */
    const val GEMMA = "gemma3-1b-it-int4"
}

/**
 * MediaPipe LiteRT (Qwen) LLM inference. Builds one `LlmInference` session per model
 * path (cached) and runs the combined system+user prompt. Called off the main thread by
 * the core (the `OnDeviceLlm.generate` FFI is synchronous-blocking).
 */
class LiteRtEngine(private val context: Context) {
    @Volatile private var engine: com.google.mediapipe.tasks.genai.llminference.LlmInference? = null
    @Volatile private var loadedPath: String? = null

    /**
     * Single-flight for the WHOLE load+inference (iOS LiteRTEngine.gate). Field
     * SIGBUS crashes on iOS: a second engine built over the same weight cache
     * truncated the file the first still had mmap'd. Only the holder may touch the
     * engine or the cache, and it releases the gate only when the call has truly
     * finished — a wedged call keeps the lane failing soft instead of crashing.
     */
    private val gate = java.util.concurrent.Semaphore(1)

    companion object {
        /** Hard cap on a single load+inference wait (iOS: 90 s — the first call
         *  after a download legitimately blows through it building the weight
         *  cache; the orphaned call keeps running behind the gate). */
        private const val TIMEOUT_S = 90L
    }

    private fun markerFile(modelPath: String) = java.io.File("$modelPath.loading")

    /**
     * iOS LiteRTEngine.preflight: the crashes the runtime can't catch, seen coming.
     * A surviving marker file means the process died inside load OR inference →
     * drop the weight cache and rebuild; after two consecutive crashes the lane is
     * disabled (throws — degrades soft) until the model is re-downloaded. Also
     * checks disk for the cache build and RAM for the engine + KV cache.
     */
    private fun preflight(modelPath: String, buildingEngine: Boolean) {
        val model = java.io.File(modelPath)
        val marker = markerFile(modelPath)
        val cache = java.io.File("$modelPath.xnnpack_cache")

        var priorCrashes = 0
        if (marker.exists()) {
            priorCrashes = marker.readText().trim().toIntOrNull() ?: 1
            cache.delete()
            Log.e("com.inbox2.engine", "LiteRT: previous model load/inference crashed (${priorCrashes}x); dropped weight cache")
        }
        if (priorCrashes >= 2) {
            throw RuntimeException("model crashed ${priorCrashes}x in a row; lane disabled until the model is re-downloaded")
        }

        val modelSize = model.length()
        val cacheSize = if (cache.exists()) cache.length() else 0L
        val diskNeeded = maxOf(0L, modelSize - cacheSize) + (256L shl 20)
        val diskAvailable = model.parentFile?.usableSpace ?: Long.MAX_VALUE
        if (diskAvailable < diskNeeded) {
            throw RuntimeException("not enough free space to build the weight cache (need ~${diskNeeded shr 20} MB, have ${diskAvailable shr 20} MB)")
        }

        // RAM: building an engine dirties the KV cache + executor scratch (a cache
        // build holds ~the model dirty too); a warm engine only needs scratch.
        val cacheBuilt = cacheSize >= modelSize / 2
        val ramNeeded = (if (buildingEngine) (if (cacheBuilt) 0L else modelSize) + (512L shl 20) else 128L shl 20)
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
        if (am != null) {
            val mi = android.app.ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            if (mi.availMem in 1 until ramNeeded) {
                throw RuntimeException("not enough memory to run the model (need ~${ramNeeded shr 20} MB, have ${mi.availMem shr 20} MB)")
            }
        }

        marker.writeText("${priorCrashes + 1}")
    }

    private fun needsEngineBuild(modelPath: String) = engine == null || loadedPath != modelPath

    /**
     * Release the resident engine (weights + KV cache) so a backgrounded process
     * isn't holding ~1.6 GB while suspended (the OOM-jetsam condition). Gate-guarded:
     * if a generation is in flight it owns the engine + the weight-cache mmap, so we
     * skip rather than close underneath it (a close mid-inference would SIGSEGV). The
     * next `generate()` simply rebuilds the engine via `engineFor`.
     */
    @Synchronized
    fun unload() {
        if (!gate.tryAcquire()) {
            Log.i("com.inbox2.engine", "LiteRT unload skipped: generation in flight")
            return
        }
        try {
            engine?.let {
                runCatching { it.close() }
                Log.i("com.inbox2.engine", "LiteRT engine unloaded (background/memory pressure)")
            }
            engine = null
            loadedPath = null
        } finally {
            gate.release()
        }
    }

    @Synchronized
    private fun engineFor(modelPath: String): com.google.mediapipe.tasks.genai.llminference.LlmInference {
        engine?.let { if (loadedPath == modelPath) return it }
        // Don't COLD-LOAD a 0.7–1.6 GB model while backgrounded (a WorkManager sync
        // driving the triage worker): the process is the OOM killer's first victim
        // there. A warm engine keeps serving; only a load is refused. The core turns
        // this error into its snippet-summary fallback (`ai_worker::summarize`), so
        // the job completes rather than being charged toward poison (iOS BridgeLLM).
        if (!com.inbox2.app.AppActivity.isForeground) {
            throw uniffi.inbox2_core.FfiException.Engine("on-device model load deferred: app is backgrounded")
        }
        // Drop the old engine BEFORE building the new one: on a variant switch
        // (Qwen <-> Gemma) the two engines' weights + KV caches otherwise coexist
        // for the whole build — enough to OOM on its own (iOS field SIGSEGVs).
        engine?.close()
        engine = null
        loadedPath = null
        val options = com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions.builder()
            .setModelPath(modelPath)
            // Total token budget (input + output) — the core's shared
            // ON_DEVICE_CONTEXT_TOKENS over the FFI: matches the ekv4096 KV cache
            // of the Qwen .task bundle and the desktop sidecar's --ctx-size. The
            // triage prompt plus a direction-tagged 8-message thread needs well
            // over the old 1024.
            .setMaxTokens(uniffi.inbox2_core.onDeviceContextTokens().toInt())
            .build()
        val e = com.google.mediapipe.tasks.genai.llminference.LlmInference.createFromOptions(context, options)
        engine = e; loadedPath = modelPath
        return e
    }

    fun generate(modelPath: String, system: String, user: String): String {
        // Per-model chat template, mirrors iOS BridgeLLM (the desktop sidecar needs
        // neither: llama-server applies the GGUF-embedded template). The `.task`
        // bundles bake in the stop token but NOT the turn markers, so wrap turns
        // ourselves; raw concatenated text degrades output quality badly.
        //   - Qwen: ChatML, with a real system turn.
        //   - Gemma: <start_of_turn> markers; no system role — fold into the user turn.
        val prompt = if (modelPath.contains(BridgeModelIds.GEMMA)) {
            val content = if (system.isBlank()) user else "$system\n\n$user"
            "<start_of_turn>user\n$content<end_of_turn>\n<start_of_turn>model\n"
        } else if (system.isBlank())
            "<|im_start|>user\n$user<|im_end|>\n<|im_start|>assistant\n"
        else
            "<|im_start|>system\n$system<|im_end|>\n<|im_start|>user\n$user<|im_end|>\n<|im_start|>assistant\n"
        // A fresh session per call: independent context (no cross-call accumulation)
        // and explicit sampling — read over the FFI from the core's shared free-lane
        // constants (`bridge::ON_DEVICE_*`) so the same input scores the same on
        // desktop's sidecar and iOS.
        if (!gate.tryAcquire(2, java.util.concurrent.TimeUnit.SECONDS)) {
            throw RuntimeException("a previous on-device generation is still running (likely the first-load cache build)")
        }
        // Run load + inference on its own thread so a hang can't block the core's
        // triage worker past the timeout; the orphan (if it ever returns) releases
        // the gate when it has truly finished.
        var outcome: Result<String>? = null
        val done = java.util.concurrent.CountDownLatch(1)
        Thread({
            outcome = runCatching {
                // Arms the crash marker; disarmed below on every non-crash exit, so
                // a surviving marker means the process died inside load/inference.
                preflight(modelPath, needsEngineBuild(modelPath))
                val sessionOptions =
                    com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession.LlmInferenceSessionOptions.builder()
                        .setTemperature(uniffi.inbox2_core.onDeviceTemperature())
                        .setTopK(uniffi.inbox2_core.onDeviceTopK())
                        .build()
                val session = com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
                    .createFromOptions(engineFor(modelPath), sessionOptions)
                try {
                    session.addQueryChunk(prompt)
                    session.generateResponse().trim()
                } finally {
                    session.close()
                }
            }
            markerFile(modelPath).delete()
            gate.release()
            done.countDown()
        }, "litert-generate").start()
        if (!done.await(TIMEOUT_S, java.util.concurrent.TimeUnit.SECONDS)) {
            // Don't touch the engine here — the call still owns the gate (and the
            // weight-cache mmap). It finishes or wedges on its own; the gate keeps
            // the next call from doubling up on the cache.
            throw RuntimeException("on-device generation timed out")
        }
        return outcome!!.getOrThrow()
    }
}
