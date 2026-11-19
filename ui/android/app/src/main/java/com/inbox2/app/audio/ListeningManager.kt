package com.inbox2.app.audio

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Bundle
import android.speech.SpeechRecognizer
import com.inbox2.app.engine.BridgeCapability
import com.inbox2.app.engine.BridgeLane
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.VoicePrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream

/**
 * Bridge STT (iOS ListeningManager). Resolves the lane via the shared core:
 *  - native → Android SpeechRecognizer (live)
 *  - openai → record a 16 kHz WAV (AudioRecord) then `bridge_openai_transcribe`
 *  - free   → WhisperKit is iOS-only; falls back to native
 * The native lane is the press-to-talk path on real devices; on the emulator (no
 * recognizer) it falls back to the OpenAI lane when a key is set.
 */
class ListeningManager(private val context: Context, private val engine: EngineModel, private val prefs: VoicePrefs) {
    private var recognizer: SpeechRecognizer? = null
    private var recorder: AudioRecord? = null
    private var recordBuffer: ByteArrayOutputStream? = null
    @Volatile private var recording = false

    /** Live mic level 0…1 (native RMS or the recorded PCM), for the bars + orb (iOS `level`). */
    var onLevel: ((Float) -> Unit)? = null
    /** The running transcript while the native recognizer listens (iOS `transcript`). */
    var onPartial: ((String) -> Unit)? = null

    private val nativeAvailable get() = SpeechRecognizer.isRecognitionAvailable(context)

    fun resolveLane(): String =
        engine.effectiveLane(BridgeCapability.STT.raw, prefs.lane(BridgeCapability.STT), prefs.hasKey)

    /** True if any STT path is usable right now (native recognizer or an OpenAI key). */
    fun isAvailable(): Boolean = nativeAvailable || prefs.hasKey

    // ── native (live) ─────────────────────────────────────────────────────────
    fun startNative(onResult: (String) -> Unit, onError: (String) -> Unit) {
        if (!nativeAvailable) { onError("Voice input isn't available"); return }
        recognizer = startFreeFormRecognizer(context, object : RecognitionAdapter() {
            override fun onResults(results: Bundle) { onResult(results.firstTranscript().orEmpty()) }
            override fun onError(error: Int) { onError(errorMessage(error)) }
            // RMS arrives in dB (about -2…10); fold it onto 0…1 for the meters.
            override fun onRmsChanged(rmsdB: Float) { onLevel?.invoke(((rmsdB + 2f) / 12f).coerceIn(0f, 1f)) }
            override fun onPartialResults(partialResults: Bundle?) { partialResults?.firstTranscript()?.let { onPartial?.invoke(it) } }
        }, preferOffline = false)
    }

    /** Orb released on the native lane: finish the utterance — the final text arrives via
     *  onResult (iOS finalizeAndFinishThroughEndOfInput). */
    fun stopNative() { runCatching { recognizer?.stopListening() } }

    fun cancelNative() { runCatching { recognizer?.cancel(); recognizer?.destroy() }; recognizer = null }

    /** Abort whatever is in flight without handing anything to the agent (iOS cancel). */
    fun cancel() {
        cancelNative()
        recording = false
        runCatching { recorder?.stop(); recorder?.release() }; recorder = null; recordBuffer = null
    }

    private fun errorMessage(code: Int): String = when (code) {
        SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "I didn't catch that. Hold the orb and try again."
        SpeechRecognizer.ERROR_AUDIO -> "The microphone isn't available right now."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone access is off."
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Voice input needs a connection right now."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Voice input is busy. Try again."
        else -> "Couldn't hear that ($code)."
    }

    // ── openai (record → transcribe) ───────────────────────────────────────────
    fun startRecording() {
        if (recording) return
        val rate = 16_000
        val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        @Suppress("MissingPermission")
        val rec = AudioRecord(MediaRecorder.AudioSource.MIC, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, rate))
        recorder = rec
        recordBuffer = ByteArrayOutputStream()
        recording = true
        rec.startRecording()
        Thread {
            val buf = ByteArray(2048)
            while (recording) {
                val n = rec.read(buf, 0, buf.size)
                if (n > 0) {
                    recordBuffer?.write(buf, 0, n)
                    // Level for the meters: RMS of the 16-bit samples, folded onto 0…1.
                    var sum = 0.0; var i = 0
                    while (i + 1 < n) { val s = ((buf[i + 1].toInt() shl 8) or (buf[i].toInt() and 0xff)).toShort().toDouble(); sum += s * s; i += 2 }
                    val rms = Math.sqrt(sum / (n / 2).coerceAtLeast(1)) / 32768.0
                    onLevel?.invoke((rms * 6).toFloat().coerceIn(0f, 1f))
                }
            }
        }.start()
    }

    /** Stop recording and transcribe via OpenAI. Returns the text, or null. */
    suspend fun stopAndTranscribe(): String? {
        recording = false
        val pcm = recordBuffer?.toByteArray() ?: return null
        runCatching { recorder?.stop(); recorder?.release() }; recorder = null; recordBuffer = null
        // Anything under 0.1 s (1600 samples) is a tap, not speech — say so instead of
        // sending it (iOS transcribeRecorded).
        if (pcm.size < 3200 || !prefs.hasKey) return ""
        val wav = pcmToWav(pcm, 16_000)
        return engine.bridgeOpenAITranscribe(prefs.openAIKey, wav)
    }

    fun shutdown() { cancelNative(); recording = false; runCatching { recorder?.release() }; recorder = null }

    /** Wrap raw 16-bit mono PCM in a WAV header. */
    private suspend fun pcmToWav(pcm: ByteArray, rate: Int): ByteArray = withContext(Dispatchers.Default) {
        val out = ByteArrayOutputStream()
        val totalDataLen = pcm.size + 36
        val byteRate = rate * 2
        fun w(s: String) = out.write(s.toByteArray(Charsets.US_ASCII))
        fun i32(v: Int) = out.write(byteArrayOf((v and 0xff).toByte(), ((v shr 8) and 0xff).toByte(), ((v shr 16) and 0xff).toByte(), ((v shr 24) and 0xff).toByte()))
        fun i16(v: Int) = out.write(byteArrayOf((v and 0xff).toByte(), ((v shr 8) and 0xff).toByte()))
        w("RIFF"); i32(totalDataLen); w("WAVE"); w("fmt "); i32(16); i16(1); i16(1)
        i32(rate); i32(byteRate); i16(2); i16(16); w("data"); i32(pcm.size); out.write(pcm)
        out.toByteArray()
    }
}
