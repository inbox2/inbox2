package com.inbox2.app.audio

import android.content.Context
import android.media.MediaPlayer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.languageid.LanguageIdentifier
import com.inbox2.app.engine.BridgeLane
import com.inbox2.app.engine.BridgeCapability
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.VoicePrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.io.File
import java.text.BreakIterator
import java.util.Locale

/**
 * Bridge TTS (iOS Speaker). Resolves the lane via the shared core's `effective_lane`:
 *  - openai → `bridge_openai_tts` (tts-1 MP3) played through MediaPlayer
 *  - native → Android TextToSpeech, with per-sentence language routing
 *  - free   → sherpa-onnx Kokoro when wired, else falls back to native TextToSpeech
 * Android has a real native TTS, so the free lane degrades gracefully until the
 * sherpa-onnx engine is added (see docs/Android-App.md §9).
 *
 * Like iOS, the native path splits the reply into consecutive same-language runs (ML Kit
 * on-device language ID, the Android counterpart to iOS NaturalLanguage) and speaks each
 * run with a matching installed voice — so an English brief that names a Dutch meeting
 * reads the Dutch part in a Dutch voice when one is installed. Short or low-confidence
 * spans default to the device locale (only a clearly non-default sentence switches).
 */
class Speaker(private val context: Context, private val engine: EngineModel, private val prefs: VoicePrefs) {
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var player: MediaPlayer? = null
    private var langId: LanguageIdentifier? = null

    /** True while TTS audio is playing (either lane) — the Bridge arms the barge-in
     *  mic while this is set, mirroring iOS `Speaker.isSpeaking`. */
    private val speakingState = MutableStateFlow(false)
    val speaking: StateFlow<Boolean> = speakingState

    /** The last utterance id of the current native run — speaking ends when it's done. */
    @Volatile private var lastUtteranceId: String? = null

    private fun ensureTts() {
        if (tts != null) return
        tts = TextToSpeech(context.applicationContext) { status ->
            ttsReady = status == TextToSpeech.SUCCESS
            tts?.language = Locale.getDefault()
        }.apply {
            // Callbacks arrive on a TTS engine thread; MutableStateFlow is thread-safe.
            setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) { speakingState.value = true }
                override fun onDone(utteranceId: String?) {
                    if (utteranceId == lastUtteranceId) speakingState.value = false
                }
                @Deprecated("TTS API")
                override fun onError(utteranceId: String?) {
                    if (utteranceId == lastUtteranceId) speakingState.value = false
                }
            })
        }
    }

    /** Preload the TTS engine (and the language-ID model) on Bridge open so the first
     *  brief speaks without the engine-init pause (iOS `warmUpVoiceOnce`). */
    fun warmUp() {
        ensureTts()
        if (langId == null) langId = LanguageIdentification.getClient()
    }

    /** [reader] = the read-aloud surface (email summaries), which may carry its own
     *  voice per lane; the Bridge voice otherwise (iOS VoiceSurface). */
    suspend fun speak(text: String, reader: Boolean = false) {
        val t = dropLargeNumbers(text)
        if (t.isBlank()) return
        val lane = engine.effectiveLane(BridgeCapability.TTS.raw, prefs.lane(BridgeCapability.TTS), prefs.hasKey)
        when (lane) {
            BridgeLane.OPENAI.raw -> speakOpenAI(t, reader)
            else -> speakNative(t, reader)   // native + (free, until sherpa wired) fall here
        }
    }

    private companion object {
        /** Numbers above this aren't worth listening to — order numbers, tracking codes,
         *  ticket IDs — the voice reads them digit by digit for seconds. Mirrors the
         *  core's `sanitize_spoken` (which covers core-generated speech) and iOS
         *  `Speaker.droppingLargeNumbers`; this covers texts the app voices directly,
         *  like the reader's stored triage summaries. Grouped figures like "15,000"
         *  survive — the separator splits them into small runs. */
        const val MAX_SPOKEN_NUMBER = 10_000uL
        val DIGIT_RUN = Regex("\\d+")
        fun dropLargeNumbers(s: String): String = DIGIT_RUN.replace(s) { m ->
            // A run too long to parse counts as large.
            if ((m.value.toULongOrNull() ?: ULong.MAX_VALUE) <= MAX_SPOKEN_NUMBER) m.value else ""
        }
    }

    private suspend fun speakOpenAI(text: String, reader: Boolean) {
        val mp3 = engine.bridgeOpenAITTS(prefs.openAIKey, text, prefs.ttsVoice(reader)) ?: return speakNative(text, reader)
        withContext(Dispatchers.IO) {
            val f = File(context.cacheDir, "tts.mp3").apply { writeBytes(mp3) }
            stop()
            player = MediaPlayer().apply {
                setDataSource(f.absolutePath); prepare(); start()
                setOnCompletionListener { it.release(); if (player === it) player = null; speakingState.value = false }
                setOnErrorListener { mp, _, _ -> mp.release(); if (player === mp) player = null; speakingState.value = false; true }
            }
            speakingState.value = true
        }
    }

    private suspend fun speakNative(text: String, reader: Boolean) {
        ensureTts()
        val engineTts = tts ?: return
        val segments = languageSegments(text)
        // The user's chosen native voice (iOS appleVoiceId), applied only to runs in the same
        // language so the per-sentence multilingual routing still switches voices elsewhere.
        val preferredVoice = prefs.nativeVoiceId(reader).takeIf { it.isNotEmpty() }
            ?.let { id -> engineTts.voices?.firstOrNull { it.name == id } }
        // Stop anything playing, then enqueue each language run with its own voice. The
        // language set immediately before speak() binds to that queued utterance.
        engineTts.stop()
        lastUtteranceId = "bridge-${segments.size - 1}"   // before enqueue: onDone may race
        segments.forEachIndexed { i, seg ->
            val loc = seg.locale?.takeIf { engineTts.isLanguageAvailable(it) >= TextToSpeech.LANG_AVAILABLE }
                ?: Locale.getDefault()
            engineTts.language = loc
            if (preferredVoice != null && preferredVoice.locale.language == loc.language) engineTts.voice = preferredVoice
            val mode = if (i == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
            engineTts.speak(seg.text, mode, null, "bridge-$i")
        }
    }

    private data class Segment(val text: String, val locale: Locale?)

    /** Split into sentences (BreakIterator), detect each sentence's language, and merge
     *  consecutive same-language sentences into runs. Mirrors iOS `languageSegments`. */
    private suspend fun languageSegments(text: String): List<Segment> = withContext(Dispatchers.Default) {
        val sentences = splitSentences(text)
        val runs = mutableListOf<Pair<StringBuilder, Locale?>>()
        for (s in sentences) {
            val loc = detectLocale(s)
            val last = runs.lastOrNull()
            if (last != null && last.second == loc) last.first.append(s)
            else runs.add(StringBuilder(s) to loc)
        }
        if (runs.isEmpty()) listOf(Segment(text, null)) else runs.map { Segment(it.first.toString(), it.second) }
    }

    private fun splitSentences(text: String): List<String> {
        val it = BreakIterator.getSentenceInstance(Locale.getDefault())
        it.setText(text)
        val out = mutableListOf<String>()
        var start = it.first(); var end = it.next()
        while (end != BreakIterator.DONE) {
            text.substring(start, end).takeIf { s -> s.isNotEmpty() }?.let(out::add)
            start = end; end = it.next()
        }
        return if (out.isEmpty()) listOf(text) else out
    }

    /** Identify a sentence's language → Locale, or null (use the device default). Short
     *  or uncertain spans return null, so only a clearly non-default sentence switches. */
    private fun detectLocale(s: String): Locale? {
        val trimmed = s.trim()
        if (trimmed.length < 4) return null
        val id = langId ?: LanguageIdentification.getClient().also { langId = it }
        val code = runCatching { Tasks.await(id.identifyLanguage(trimmed)) }.getOrNull()
        if (code == null || code == LanguageIdentifier.UNDETERMINED_LANGUAGE_TAG) return null
        return runCatching { Locale.forLanguageTag(code) }.getOrNull()
    }

    fun stop() {
        runCatching { player?.stop(); player?.release() }; player = null
        runCatching { tts?.stop() }
        speakingState.value = false
    }

    fun shutdown() {
        stop()
        runCatching { tts?.shutdown() }; tts = null
        runCatching { langId?.close() }; langId = null
    }
}
