package com.inbox2.app.audio

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.content.ContextCompat

/** A `RecognitionListener` with empty defaults, so a caller overrides only what it uses. */
open class RecognitionAdapter : RecognitionListener {
    override fun onReadyForSpeech(params: Bundle?) {}
    override fun onBeginningOfSpeech() {}
    override fun onRmsChanged(rmsdB: Float) {}
    override fun onBufferReceived(buffer: ByteArray?) {}
    override fun onEndOfSpeech() {}
    override fun onError(error: Int) {}
    override fun onResults(results: Bundle) {}
    override fun onPartialResults(partialResults: Bundle?) {}
    override fun onEvent(eventType: Int, params: Bundle?) {}
}

/** One free-form, partial-results `SpeechRecognizer`, already listening — the single
 *  construction shared by the Bridge mic, barge-in and voice triage. */
internal fun startFreeFormRecognizer(context: Context, listener: RecognitionListener, preferOffline: Boolean): SpeechRecognizer =
    SpeechRecognizer.createSpeechRecognizer(context).apply {
        setRecognitionListener(listener)
        startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            if (preferOffline) putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        })
    }

internal fun Bundle.firstTranscript(): String? = getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

/**
 * The armed keyword-spotting loop behind [BargeInListener] and [TriageListener].
 * Android's `SpeechRecognizer` ends a session after each silence/result (unlike the
 * iOS streaming recognition task), so the recognizer is restarted while armed;
 * offline recognition is preferred (private, low-latency) and the recognizer records
 * from the VOICE_RECOGNITION source, whose echo cancellation keeps the Bridge's own
 * voice from being heard as input. No-ops without mic permission or a recognizer, so
 * it's purely additive: tapping still stops speech. Main thread only.
 *
 * A subclass implements [matched] over the whole-word split of the freshly-spoken
 * text; returning true fires once per run (until the next [start]).
 */
abstract class KeywordListener(protected val context: Context) {
    private companion object {
        const val RESTART_DELAY_MS = 250L
        /** Give up after this many recognizer errors with no speech heard between them
         *  (e.g. no offline model) instead of spinning for the whole utterance. */
        const val MAX_CONSECUTIVE_ERRORS = 8
    }

    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var armed = false
    private var fired = false
    private var errors = 0

    /** True once the recognizer loop is running (drives the listening pill). */
    val isListening: Boolean get() = armed && recognizer != null

    /** Begin listening. Requires already-granted mic permission (the push-to-talk flow
     *  requests it) and an available recognizer; otherwise no-op — a TTS playback
     *  should never spring a permission dialog. */
    fun start() {
        if (armed) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) return
        armed = true
        fired = false
        errors = 0
        listen()
    }

    fun stop() {
        armed = false
        handler.removeCallbacksAndMessages(null)
        destroyRecognizer()
    }

    private fun listen() {
        if (!armed) return
        destroyRecognizer()
        recognizer = startFreeFormRecognizer(context, object : RecognitionAdapter() {
            override fun onPartialResults(partialResults: Bundle?) { scan(partialResults?.firstTranscript()) }
            override fun onResults(results: Bundle) {
                errors = 0
                scan(results.firstTranscript())
                restart()
            }
            override fun onError(error: Int) {
                errors += 1
                if (errors <= MAX_CONSECUTIVE_ERRORS) restart() else stop()
            }
            override fun onBeginningOfSpeech() { errors = 0 }
        }, preferOffline = true)
    }

    private fun restart() {
        if (!armed || fired) return
        handler.postDelayed({ if (armed) listen() }, RESTART_DELAY_MS)
    }

    private fun destroyRecognizer() {
        runCatching { recognizer?.cancel(); recognizer?.destroy() }
        recognizer = null
    }

    /** Whole-word split of the freshly-spoken tail → [matched]; fires at most once per run. */
    private fun scan(text: String?) {
        if (fired || text.isNullOrBlank()) return
        val words = text.lowercase().split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }
        if (words.isNotEmpty() && matched(words)) fired = true
    }

    /** Act on a keyword in [words] (lowercased, in spoken order) and return true to end the run. */
    protected abstract fun matched(words: List<String>): Boolean
}
