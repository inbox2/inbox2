package com.inbox2.app.audio

import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.VoicePrefs
import com.inbox2.app.engine.nluBridgeConfig
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConversationAction
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * "Read this mail aloud, then offer to file it" (iOS `ReadAloudController`) —
 * drives the reader's speaker button without leaving the screen.
 *
 * Lifecycle: THINKING while the text is resolved → SPEAKING while the shared
 * [Speaker] reads it (with the "trash or archive?" question appended) →
 * LISTENING for a 5 s hands-free window after. A matched keyword calls back the
 * host ([start]'s `onTriage`) to apply the action; a spoken dismissal, a second
 * tap, or the window elapsing closes it silently.
 *
 * Speaks the stored triage summary (Small, falling back to Medium) — instant,
 * deterministic, identical to the screen; the generated email-to-voice path is
 * only the fallback for threads the triage worker hasn't summarized yet.
 */
class ReadAloudController(
    private val engine: EngineModel,
    private val prefs: VoicePrefs,
    private val speaker: Speaker,
    private val triage: TriageListener,
    private val scope: CoroutineScope,
) {
    enum class Phase { IDLE, THINKING, SPEAKING, LISTENING }

    private val _phase = MutableStateFlow(Phase.IDLE)
    val phase: StateFlow<Phase> = _phase
    private val _conversationId = MutableStateFlow<String?>(null)
    val conversationId: StateFlow<String?> = _conversationId

    companion object {
        /** The spoken question appended after the mail — the keywords are exactly
         *  those [TriageListener] matches (iOS parity). */
        const val TRIAGE_PROMPT = "\n\nWould you like to trash it or archive it?"
        private const val LISTEN_WINDOW_MS = 5_000L
    }

    private var readJob: Job? = null
    private var watchJob: Job? = null
    private var windowJob: Job? = null
    private var onTriage: ((ConversationAction) -> Unit)? = null
    private var armed = false

    init {
        triage.onTriage = { action -> handleTriage(action) }
        triage.onCancel = { stop() }
    }

    /** True while this controller is reading the given thread. */
    fun isActive(id: String) = _conversationId.value == id && _phase.value != Phase.IDLE

    /** Start the read-aloud + voice triage for a thread, staying on screen.
     *  `onTriage` is called with the spoken action so the host applies it. */
    fun start(convo: Conversation, onTriage: (ConversationAction) -> Unit) {
        stop()   // supersede any read in flight
        this.onTriage = onTriage
        _conversationId.value = convo.id
        armed = true
        _phase.value = Phase.THINKING
        readJob = scope.launch {
            val short = convo.aiSummaryShort?.trim().orEmpty()
            val medium = convo.aiSummaryMedium?.trim().orEmpty()
            val stored = short.ifEmpty { medium }.ifEmpty { null }
            val text = stored ?: runCatching {
                engine.bridgeEmailVoice(nluBridgeConfig(engine, prefs), convo.id)?.text
            }.getOrNull()
            if (text.isNullOrBlank()) {
                finishIdle()
                return@launch
            }
            _phase.value = Phase.SPEAKING
            watchSpeaker()
            speaker.speak(text + TRIAGE_PROMPT, reader = true)
            readJob = null
        }
    }

    /** Speak a specific stored summary / message verbatim (the "Speak with" tester) — no
     *  triage window, no generation. Drives the same SPEAKING state as the read button, so
     *  the header speaker lights up and a second tap stops it (iOS speakSummary). */
    fun speakPlain(text: String) {
        if (text.isBlank()) return
        stop()                 // supersede any read in flight; clears armed
        _phase.value = Phase.SPEAKING
        watchSpeaker()         // armed == false → returns to idle when playback ends
        readJob = scope.launch { speaker.speak(text, reader = true); readJob = null }
    }

    /** Stop everything (a second tap / a new read / a spoken cancel), cutting speech. */
    fun stop() {
        readJob?.cancel(); readJob = null
        speaker.stop()
        finishIdle()
    }

    /** When playback ends on an armed read, open the hands-free answer window —
     *  the mic stays off DURING playback so recognition never hears our own voice
     *  as input (the iOS sequencing, adapted to SpeechRecognizer). */
    private fun watchSpeaker() {
        watchJob?.cancel()
        watchJob = scope.launch {
            speaker.speaking.first { it }
            speaker.speaking.first { !it }
            if (_phase.value == Phase.SPEAKING) {
                if (armed) beginListenWindow() else finishIdle()
            }
        }
    }

    private fun beginListenWindow() {
        triage.start()
        if (!triage.isListening) {
            finishIdle()   // no permission / recognizer — the read just retires
            return
        }
        _phase.value = Phase.LISTENING
        windowJob?.cancel()
        windowJob = scope.launch {
            delay(LISTEN_WINDOW_MS)
            if (_phase.value == Phase.LISTENING) finishIdle()
        }
    }

    private fun handleTriage(action: ConversationAction) {
        val cb = onTriage
        readJob?.cancel(); readJob = null
        speaker.stop()
        finishIdle()
        cb?.invoke(action)
    }

    private fun finishIdle() {
        armed = false
        watchJob?.cancel(); watchJob = null
        windowJob?.cancel(); windowJob = null
        triage.stop()
        onTriage = null
        _conversationId.value = null
        _phase.value = Phase.IDLE
    }
}
