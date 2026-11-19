package com.inbox2.app.engine

import android.content.Context

/**
 * Per-capability Bridge lane preference + the OpenAI key (iOS VoiceEngineManager). On
 * Android there's no native LLM lane, so the free (LiteRT) lane *is* the on-device path;
 * defaults: TTS = free, STT = native (if a SpeechRecognizer exists, resolved by the
 * core), NLU = free. Lane choices are plain SharedPreferences; the OpenAI key and HF
 * token live in `SecureStore` (EncryptedSharedPreferences over an Android Keystore
 * master key), the counterpart of the iOS Keychain.
 */
class VoicePrefs(context: Context) {
    private val appCtx = context.applicationContext
    private val sp = appCtx.getSharedPreferences("inbox2_voice", Context.MODE_PRIVATE)

    var openAIKey: String
        get() = com.inbox2.app.SecureStore.get(appCtx, com.inbox2.app.SecureStore.OPENAI_KEY) ?: ""
        set(v) { com.inbox2.app.SecureStore.set(appCtx, com.inbox2.app.SecureStore.OPENAI_KEY, v) }

    var keyValidated: Boolean
        get() = sp.getBoolean("openai_validated", false)
        set(v) { sp.edit().putBoolean("openai_validated", v).apply() }

    val hasKey: Boolean get() = openAIKey.isNotBlank()

    fun lane(cap: BridgeCapability): BridgeLane {
        val raw = sp.getString("lane_${cap.raw}", null)
        return BridgeLane.entries.firstOrNull { it.raw == raw } ?: defaultLane(cap)
    }

    fun setLane(cap: BridgeCapability, lane: BridgeLane) {
        sp.edit().putString("lane_${cap.raw}", lane.raw).apply()
    }

    private fun defaultLane(cap: BridgeCapability) = when (cap) {
        BridgeCapability.TTS -> BridgeLane.FREE
        BridgeCapability.STT -> BridgeLane.NATIVE
        BridgeCapability.NLU -> BridgeLane.FREE
    }

    var hfToken: String
        get() = com.inbox2.app.SecureStore.get(appCtx, com.inbox2.app.SecureStore.HF_TOKEN) ?: ""
        set(v) { com.inbox2.app.SecureStore.set(appCtx, com.inbox2.app.SecureStore.HF_TOKEN, v) }

    val hasHfToken: Boolean get() = hfToken.isNotBlank()

    /**
     * The free NLU lane's model variant (manifest id): Qwen (default — best quality,
     * multilingual) or Gemma (smaller and faster, English-only). BridgeLLM reads this
     * at generate time to pick the engine file (iOS VoiceEngineManager.freeNluModel).
     */
    var freeNluModel: String
        get() = sp.getString("free_nlu_model", BridgeModelIds.QWEN) ?: BridgeModelIds.QWEN
        set(v) { sp.edit().putString("free_nlu_model", v).apply() }

    /** OpenAI tts-1 voice (alloy/echo/fable/onyx/nova/shimmer) — the Bridge voice. */
    var ttsVoice: String
        get() = sp.getString("tts_voice", "alloy") ?: "alloy"
        set(v) { sp.edit().putString("tts_voice", v).apply() }

    /** Chosen on-device (native TextToSpeech) voice name, or "" for the engine default
     *  (iOS VoiceEngineManager.appleVoiceId). Honored by the native/free TTS lanes. */
    var nativeVoiceId: String
        get() = sp.getString("native_voice", "") ?: ""
        set(v) { sp.edit().putString("native_voice", v).apply() }

    // The read-aloud surface (email summaries) can have its own voice per lane; null =
    // "Same as Bridge" (iOS readerOpenAIVoice / readerAppleVoiceId).
    var readerTtsVoice: String?
        get() = sp.getString("reader_tts_voice", null)
        set(v) { sp.edit().putString("reader_tts_voice", v).apply() }
    var readerNativeVoiceId: String?
        get() = sp.getString("reader_native_voice", null)
        set(v) { sp.edit().putString("reader_native_voice", v).apply() }

    /** The effective voice for a surface (iOS `openAIVoice(for:)` / `appleVoiceId(for:)`). */
    fun ttsVoice(reader: Boolean) = if (reader) readerTtsVoice ?: ttsVoice else ttsVoice
    fun nativeVoiceId(reader: Boolean) = if (reader) readerNativeVoiceId ?: nativeVoiceId else nativeVoiceId

    companion object {
        val OPENAI_VOICES = listOf("alloy", "echo", "fable", "onyx", "nova", "shimmer")
    }
}
