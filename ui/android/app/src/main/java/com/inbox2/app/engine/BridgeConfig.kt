package com.inbox2.app.engine

import uniffi.inbox2_core.FfiBridgeConfig
import uniffi.inbox2_core.FfiBridgeReply

/**
 * The NLU generation config, shared by the Bridge UI and the background triage worker
 * (iOS `VoiceEngineManager.bridgeConfig`). This is the single source of truth: the
 * Bridge's spoken turns and the worker that classifies/summarizes the backlog must run
 * on the same model, or summaries drift from what the assistant says.
 *
 * `generation` is `openai` only when the NLU lane resolves to OpenAI (a key is present
 * and the lane preference selects it); otherwise the on-device path (`apple` is the FFI's
 * name for "use the host's OnDeviceLlm" — on Android that's LiteRT/Qwen).
 */
// `concise` (default false) requests the terse headline brief — set only on the daily
// brief call from non-car mode. `weather` (default null) is the short line the core
// appends to a morning brief. Both are ignored by every non-brief Bridge call and the
// background triage worker, so the shared config is unchanged for them.
fun nluBridgeConfig(
    engine: EngineModel,
    prefs: VoicePrefs,
    concise: Boolean = false,
    weather: String? = null,
): FfiBridgeConfig {
    val lane = engine.effectiveLane(BridgeCapability.NLU.raw, prefs.lane(BridgeCapability.NLU), prefs.hasKey)
    return if (lane == BridgeLane.OPENAI.raw)
        FfiBridgeConfig(
            generation = "openai", openaiKey = prefs.openAIKey, model = null, onDeviceModel = null,
            concise = concise, weather = weather,
        )
    else
        FfiBridgeConfig(
            generation = "apple", openaiKey = null, model = null,
            // The engine BridgeLLM will actually run (variant choice, resolved against
            // what's installed) — handed back per call and recorded as triage provenance.
            onDeviceModel = resolvedFreeNluModel(engine, prefs),
            concise = concise, weather = weather,
        )
}

/**
 * The free NLU variant that would actually run: the chosen one when installed, else the
 * other installed variant (BridgeLLM's fallback), else the choice itself. Single source
 * for the config's `onDeviceModel` so provenance matches what BridgeLLM resolves.
 */
fun resolvedFreeNluModel(engine: EngineModel, prefs: VoicePrefs): String {
    val chosen = prefs.freeNluModel
    val other = if (chosen == BridgeModelIds.QWEN) BridgeModelIds.GEMMA else BridgeModelIds.QWEN
    return when {
        engine.modelPath(chosen) != null -> chosen
        engine.modelPath(other) != null -> other
        else -> chosen
    }
}

/**
 * A stable key that changes whenever the resolved NLU config would change. Drives the
 * app-startup re-push so the triage worker stays in sync without the Bridge ever being
 * opened (iOS `aiConfigKey`).
 */
fun VoicePrefs.aiConfigKey(): String = "${lane(BridgeCapability.NLU).raw}|$hasKey|$freeNluModel"

/**
 * Map a Bridge reply to the text to speak. An OpenAI error with no text becomes spoken
 * guidance instead of silence. Shared by the phone Bridge screen and the Android Auto car
 * screen so the wording can't drift (iOS's equivalent is BridgeBrain.map).
 */
fun bridgeReplyText(reply: FfiBridgeReply): String {
    val err = reply.openaiError
    return if (!err.isNullOrEmpty() && reply.text.isBlank()) {
        "OpenAI sent an error: $err. Check your key under On-device AI in Settings."
    } else {
        reply.text
    }
}
