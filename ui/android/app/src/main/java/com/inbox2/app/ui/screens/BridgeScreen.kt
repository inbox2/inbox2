package com.inbox2.app.ui.screens

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import kotlin.math.PI
import kotlin.math.sin
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.inbox2.app.audio.BargeInListener
import com.inbox2.app.audio.ListeningManager
import com.inbox2.app.audio.Speaker
import com.inbox2.app.engine.BridgeCapability
import com.inbox2.app.engine.BridgeLane
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.VoicePrefs
import com.inbox2.app.engine.bridgeReplyText
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.bevel
import com.inbox2.app.theme.ChannelColor
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.insetCard
import com.inbox2.app.ui.components.darkKeycap
import com.inbox2.app.ui.components.pageGround
import com.inbox2.app.ui.components.groovePanel
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.launch
import uniffi.inbox2_core.FfiBridgeAction
import uniffi.inbox2_core.FfiBridgeConfig
import org.json.JSONObject

private data class Turn(val user: Boolean, val text: String)

/** Bridge (iOS BridgeView): the assistant — a Compose-canvas orb (Android alternative to
 *  the Metal sphere), a voice loop (listen → on-device/OpenAI reply → speak), and the
 *  daily brief, all over the shared Rust bridge. */
@Composable
fun BridgeScreen(
    engine: EngineModel,
    onLaunchGame: () -> Unit = {},
    /** A voice-drafted reply — the host opens a prefilled compose sheet (never sent). */
    onOpenCompose: (ComposePrefill) -> Unit = {},
    /** A voice-drafted meeting — the host opens a prefilled new-event sheet (never saved). */
    onDraftEvent: (EventDraftSeed) -> Unit = {},
    /** Set when shown as Lore's mic sheet: a close button in the top bar. */
    onClose: (() -> Unit)? = null,
) {
    val p = theme
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { VoicePrefs(ctx) }
    val speaker = remember { Speaker(ctx, engine, prefs) }
    val listener = remember { ListeningManager(ctx, engine, prefs) }
    val bargeIn = remember { BargeInListener(ctx) }
    var turns by remember { mutableStateOf<List<Turn>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var listening by remember { mutableStateOf(false) }
    var showFollowups by remember { mutableStateOf(false) }
    var transientStatus by remember { mutableStateOf<String?>(null) }
    var micDenied by remember { mutableStateOf(false) }
    // Live listening feedback (iOS ListeningManager.level / transcript) + the window
    // between release and the transcript, which a tap on the orb cancels.
    var level by remember { mutableStateOf(0f) }
    var partial by remember { mutableStateOf("") }
    var transcribing by remember { mutableStateOf(false) }
    // A brief is being composed (vs. a command being thought about) — for the status line.
    var composing by remember { mutableStateOf(false) }
    var followupNonce by remember { mutableStateOf(0) }
    val contacts = remember { mutableStateOf<List<com.inbox2.app.model.Contact>>(emptyList()) }
    LaunchedEffect(Unit) {
        listener.onLevel = { level = it }
        listener.onPartial = { partial = it }
        contacts.value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { engine.store.contacts() }
    }

    // Car mode defaults to the Bluetooth-audio connection (car kit/headset): connected →
    // on, disconnected → off. `carModeOverride` lets the user flip it for the current
    // connection; it's reset whenever the Bluetooth connection flips so each drive starts
    // from the Bluetooth-driven default. iOS VoiceEngineManager mirrors this.
    val audioManager = remember { ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    var bluetoothConnected by remember { mutableStateOf(false) }
    var carModeOverride by remember { mutableStateOf<Boolean?>(null) }
    val carMode = carModeOverride ?: bluetoothConnected
    DisposableEffect(Unit) {
        fun isBtConnected(): Boolean =
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
            }
        bluetoothConnected = isBtConnected()
        val cb = object : AudioDeviceCallback() {
            private fun refresh() {
                val now = isBtConnected()
                if (now != bluetoothConnected) { bluetoothConnected = now; carModeOverride = null }
            }
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = refresh()
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = refresh()
        }
        audioManager.registerAudioDeviceCallback(cb, null)
        onDispose { audioManager.unregisterAudioDeviceCallback(cb) }
    }

    DisposableEffect(Unit) { onDispose { bargeIn.stop(); speaker.shutdown(); listener.shutdown() } }

    // Break-in (iOS barge-in): while the Bridge speaks — a reply or a brief — keep the
    // mic open for "ok / stop / cancel". The spotter is armed BEFORE each `speaker.speak`
    // (iOS armDialog: mic-before-voice, or the first second of speech is clipped); this
    // effect only disarms it the moment speech ends.
    var commandJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    val speaking by speaker.speaking.collectAsState()
    LaunchedEffect(speaking) { if (!speaking) bargeIn.stop() }
    // Barge-in: always halt speech + the in-flight turn; "cancel" additionally abandons the
    // multi-turn command dialog, while "stop"/"ok" just quiet it (iOS handleBargeIn / #12).
    bargeIn.onStopWord = { word ->
        speaker.stop()
        commandJob?.cancel()
        loading = false
        if (word == "cancel") engine.bridgeResetDialog()
        transientStatus = "Okay, stopped."
    }

    fun bridgeConfig(): FfiBridgeConfig = com.inbox2.app.engine.nluBridgeConfig(engine, prefs)

    // Keep the background triage worker on the same AI model the Bridge uses, and warm
    // the voice engine so the first brief speaks without the TTS-init pause (iOS warmUp).
    LaunchedEffect(Unit) {
        engine.setAiConfig(bridgeConfig())
        speaker.warmUp()
    }
    val triage by engine.triage.collectAsState()

    // A null FFI reply means the core is still booting (or a transient miss) — the iOS
    // `.notReady` case. Retry once after a beat rather than speaking an error; that
    // covers the cold-launch window. Returns null only if it's still not ready.
    suspend fun produce(producer: suspend () -> uniffi.inbox2_core.FfiBridgeReply?): uniffi.inbox2_core.FfiBridgeReply? {
        producer()?.let { return it }
        transientStatus = "Still starting up…"
        kotlinx.coroutines.delay(1500)
        return producer()
    }

    // Speak a command result (an answer / clarification / draft confirmation) + log it.
    suspend fun speakResult(text: String) {
        if (text.isBlank()) return
        turns = turns + Turn(false, text)
        bargeIn.start()
        speaker.speak(text)
    }

    // Act on a command result: run the drafted reply/meeting onto the screen (never sent/
    // saved), or just speak an answer/clarification. Reversible inbox actions already ran
    // inside the core (iOS BridgeView.route).
    suspend fun route(action: FfiBridgeAction) {
        action.openaiError?.takeIf { it.isNotEmpty() }?.let { err ->
            speakResult("OpenAI sent an error: $err. Check your key under On-device AI in Settings.")
            return
        }
        when (action.kind) {
            "draft_email" -> { decodeComposeDraft(action.payloadJson)?.let { onOpenCompose(it) }; speakResult(action.spoken) }
            "draft_event" -> {
                decodeEventDraft(action.payloadJson)?.let { seed ->
                    // Spoken names → contact addresses where one matches (iOS resolveAttendees);
                    // unmatched names stay as typed for the sheet's With field.
                    val resolved = seed.attendees.map { name ->
                        contacts.value.firstOrNull { c -> c.name.isNotEmpty() && c.name.contains(name, ignoreCase = true) }?.email ?: name
                    }
                    onDraftEvent(seed.copy(attendees = resolved))
                }
                speakResult(action.spoken)
            }
            else -> speakResult(action.spoken)   // "speak" / "clarify"
        }
    }

    // A finished transcript → the intent layer: it answers by speaking, runs reversible
    // inbox actions (core-side), or hands back a DRAFT we put on screen (iOS handleCommand).
    fun handle(transcript: String) {
        if (transcript.isBlank()) {
            // Never go silent: if nothing was heard, say so instead of doing nothing (iOS).
            scope.launch { speakResult("I didn't catch that. Hold the orb and try again.") }
            return
        }
        turns = turns + Turn(true, transcript)
        loading = true
        transientStatus = null
        commandJob?.cancel()
        commandJob = scope.launch {
            val action = engine.bridgeCommand(bridgeConfig(), transcript)
                ?: run { kotlinx.coroutines.delay(1500); engine.bridgeCommand(bridgeConfig(), transcript) }
            loading = false
            if (action == null) { transientStatus = "Still starting up. Try again in a moment."; return@launch }
            transientStatus = null
            route(action)
        }
    }

    // Run a one-shot Bridge call (brief/tomorrow/week), append the reply + speak it.
    // Mic access before the first brief, so "stop/cancel" barge-in works over it (iOS
    // armDialog) — the brief speaks regardless; only the spotter needs the mic.
    val micForBargeIn = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> micDenied = !granted }
    fun ensureMicForBargeIn() {
        if (androidx.core.content.ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.RECORD_AUDIO)
            != android.content.pm.PackageManager.PERMISSION_GRANTED) micForBargeIn.launch(android.Manifest.permission.RECORD_AUDIO)
    }

    fun runBridge(producer: suspend () -> uniffi.inbox2_core.FfiBridgeReply?) {
        if (loading) return   // a double-tap can't stack two briefs (iOS isBusy)
        // A brief is a fresh interaction — stop speech, drop any open command dialog so a
        // later "archive it" can't bind to a conversation from before (iOS run()).
        speaker.stop(); bargeIn.stop()
        commandJob?.cancel(); commandJob = null
        engine.bridgeResetDialog()
        ensureMicForBargeIn()
        loading = true; composing = true
        transientStatus = null
        scope.launch {
            val r = produce(producer)
            loading = false; composing = false
            if (r == null) { transientStatus = "Still starting up. Try again in a moment."; return@launch }
            transientStatus = null
            val text = bridgeReplyText(r)
            turns = turns + Turn(false, text); showFollowups = true; followupNonce++
            bargeIn.start()
            speaker.speak(text)
        }
    }
    // Follow-ups fade a minute after each brief; the timer resets while they're used.
    LaunchedEffect(showFollowups, followupNonce) {
        if (showFollowups) { kotlinx.coroutines.delay(60_000); showFollowups = false }
    }

    val micPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        micDenied = !granted
    }
    fun beginListening() {
        if (androidx.core.content.ContextCompat.checkSelfPermission(ctx, android.Manifest.permission.RECORD_AUDIO)
            != android.content.pm.PackageManager.PERMISSION_GRANTED) { micPermission.launch(android.Manifest.permission.RECORD_AUDIO); return }
        partial = ""; level = 0f
        startListening(listener, { listening = it }, ::handle) { msg -> transientStatus = msg }
    }
    fun endListening() {
        if (!listening) return
        if (listener.resolveLane() == BridgeLane.OPENAI.raw) {
            listening = false; transcribing = true
            scope.launch {
                val text = listener.stopAndTranscribe()
                transcribing = false
                handle(text.orEmpty())
            }
        } else {
            // Native: finish the utterance; the final text arrives via onResult.
            transcribing = true
            listener.stopNative()
        }
    }

    Column(Modifier.fillMaxSize().pageGround(), horizontalAlignment = Alignment.CenterHorizontally) {
        // Top-left car-mode toggle: ON (car) speaks the full brief, OFF (normal) a terse
        // headline. Mirrors iOS BridgeView's top-left toggle.
        ScreenHeader("Bridge", leading = {
            Icon(
                SfIcon.vector(if (carMode) "car.fill" else "car"),
                if (carMode) "Car mode on" else "Car mode off",
                tint = if (carMode) ChannelColor.electricBlue else p.textMuted,
                modifier = Modifier.size(22.dp).noRippleClickable {
                    carModeOverride = !carMode
                    transientStatus = if (carModeOverride == true) "Car mode on. You'll hear full briefs." else "Car mode off. You'll hear short briefs."
                },
            )
        }, trailing = {
            // Top-right launcher for VOXEL STRIKE (iOS BridgeView's gamecontroller button).
            Icon(
                SfIcon.vector("gamecontroller.fill"), "Play Voxel Strike",
                tint = p.ringColors.getOrElse(1) { p.accentViolet },   // pink, matching iOS
                modifier = Modifier.size(24.dp).noRippleClickable { onLaunchGame() },
            )
            onClose?.let { close ->
                Icon(SfIcon.vector("xmark"), "Close", tint = p.textSecondary,
                    modifier = Modifier.size(24.dp).noRippleClickable { close() })
            }
        })
        Spacer(Modifier.weight(1f))
        // Hold the orb to talk (iOS onPressStart/onPressEnd): press starts listening,
        // release finishes the utterance. A press while a previous turn is still
        // transcribing aborts it and does NOT start a new recording.
        Box(
            Modifier.clip(CircleShape).pointerInput(Unit) {
                detectTapGestures(onPress = {
                    bargeIn.stop(); speaker.stop()
                    if (transcribing) { listener.cancel(); transcribing = false; listening = false }
                    else beginListening()
                    tryAwaitRelease()
                    endListening()
                })
            },
        ) { Orb(active = loading || listening, size = 168.dp, level = if (listening) level else if (speaking) 0.6f else null) }
        Spacer(Modifier.height(Space.s3))
        val status = transientStatus
        val ttsLane = engine.effectiveLane(BridgeCapability.TTS.raw, prefs.lane(BridgeCapability.TTS), prefs.hasKey)
        // Groovebox: the caption, hints and catch-up progress sit on one solid panel.
        Column(
            Modifier.then(if (p.groove != null) Modifier.fillMaxWidth().groovePanel().padding(vertical = Space.s3) else Modifier),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
        // While listening the caption is replaced by live audio bars + the running transcript.
        if (listening) {
            PinkAudioBars(level)
            if (partial.isNotEmpty()) Text(partial, color = p.textSecondary, style = AppFont.sm, maxLines = 1,
                modifier = Modifier.padding(top = Space.s1, start = Space.s6, end = Space.s6))
        } else {
            Text(
                when {
                    transcribing -> "Transcribing…"
                    composing -> "Composing your brief…"
                    loading -> "Thinking…"
                    status != null -> status
                    speaking -> when (ttsLane) { BridgeLane.OPENAI.raw -> "Speaking · OpenAI"; BridgeLane.NATIVE.raw -> "Speaking · on-device"; else -> "Speaking…" }
                    else -> "Talk to me"
                },
                color = if (status != null && !loading && !speaking) p.accentViolet else p.textSecondary,
                style = AppFont.md,
            )
        }
        if (!listening && !loading && !transcribing && !speaking && status == null)
            Text("Hold the orb to talk, or get your daily brief.", color = p.textTertiary, style = AppFont.xs,
                modifier = Modifier.padding(top = Space.s1))

        // Persistent mic-denied badge (iOS MicStatusBadge): the push-to-talk request was
        // refused — guide the user to enable it in system settings.
        if (micDenied) {
            Spacer(Modifier.height(Space.s2))
            Row(
                Modifier
                    .clip(androidx.compose.foundation.shape.RoundedCornerShape(com.inbox2.app.theme.Radius.full))
                    .background(p.accentDanger.copy(alpha = 0.14f))
                    .noRippleClickable {
                        ctx.startActivity(android.content.Intent(
                            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            android.net.Uri.fromParts("package", ctx.packageName, null),
                        ))
                    }
                    .padding(horizontal = Space.s3, vertical = Space.s1),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(SfIcon.vector("mic.fill"), null, tint = p.accentDanger, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(Space.s1))
                Text("Mic access is off. Tap to allow it.", color = p.accentDanger, style = AppFont.xs)
            }
        }

        // While the background worker is still classifying/summarizing the in-window
        // backlog, show its progress so the user knows the Bridge is catching up.
        if (triage.isActive && triage.inWindow > 0) {
            Spacer(Modifier.height(Space.s3))
            Column(Modifier.fillMaxWidth(0.6f)) {
                Text(
                    "Catching up · ${triage.done} of ${triage.inWindow}",
                    color = p.textTertiary, style = AppFont.xs2,
                    modifier = Modifier.padding(bottom = Space.s1),
                )
                androidx.compose.material3.LinearProgressIndicator(
                    progress = { triage.fraction },
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(3.dp)),
                    color = p.accentViolet, trackColor = p.bgInput,
                )
            }
        }
        }

        if (turns.isNotEmpty()) {
            LazyColumn(Modifier.weight(1f).fillMaxWidth()
                .then(if (p.groove != null) Modifier.padding(top = Space.s3).groovePanel() else Modifier).padding(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                items(turns.size) { i ->
                    val t = turns[i]
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (t.user) Arrangement.End else Arrangement.Start) {
                        Text(
                            t.text, color = if (t.user) (if (p.groove != null) p.onAccent else Color.White) else p.textPrimary, style = AppFont.sm,
                            modifier = Modifier.fillMaxWidth(0.85f).clip(RoundedCornerShape(if (p.groove != null) Radius.xl else Radius.lg))
                                .background(if (t.user) p.accentViolet else p.bgSurface).padding(Space.s3),
                        )
                    }
                }
            }
        } else Spacer(Modifier.weight(1f))

        // Follow-ups: tomorrow's preview and the weekly highlights. Hidden while triage is
        // catching up; when hidden (before the first brief, or after they fade), a link in
        // the same spot summons them (iOS BridgeView).
        if (triage.isActive) {
            Spacer(Modifier.height(0.dp))
        } else if (showFollowups) Row(Modifier.padding(bottom = Space.s2), horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            FollowupChip("Check tomorrow", enabled = !loading) { followupNonce++; runBridge { engine.bridgeTomorrow(bridgeConfig()) } }
            FollowupChip("Weekly highlights", enabled = !loading) { followupNonce++; runBridge { engine.bridgeWeekHighlights(bridgeConfig()) } }
        } else Row(
            Modifier.padding(bottom = Space.s2)
                // Groovebox: the hint rides a solid pill, not the grid.
                .then(if (p.groove != null) Modifier.clip(RoundedCornerShape(Radius.full)).background(p.bgPanel).padding(horizontal = Space.s3, vertical = Space.s1) else Modifier)
                .noRippleClickable { showFollowups = true; followupNonce++ },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s1),
        ) {
            Icon(SfIcon.vector("ellipsis"), null, tint = p.textMuted, modifier = Modifier.size(12.dp))
            Text("Tomorrow & weekly highlights", color = p.textMuted, style = AppFont.ui(12, androidx.compose.ui.text.font.FontWeight.Medium))
        }

        // Controls: daily brief + mic
        Row(Modifier.padding(bottom = 100.dp), horizontalArrangement = Arrangement.spacedBy(Space.s4), verticalAlignment = Alignment.CenterVertically) {
            Box(
                // Groovebox: a dark keycap.
                (p.groove?.let { Modifier.darkKeycap(it) } ?: Modifier.clip(RoundedCornerShape(Radius.full)).background(p.bgElevated))
                    .noRippleClickable(enabled = !loading) {
                        // Tapping the button again while it talks stops it (iOS TldrButton).
                        if (speaking) { speaker.stop(); return@noRippleClickable }
                        runBridge {
                            // Mornings append a short weather line (best-effort); verbosity
                            // follows car mode. Non-car mode speaks a terse headline.
                            val weather = com.inbox2.app.cloud.WeatherService.morningLine()
                            engine.bridgeBrief(
                                com.inbox2.app.engine.nluBridgeConfig(engine, prefs, concise = !carMode, weather = weather)
                            )
                        }
                    }.padding(horizontal = Space.s5, vertical = Space.s3)
                    .then(if (p.groove != null) Modifier.padding(bottom = 2.dp) else Modifier),
            ) { Text(if (speaking) "Stop" else "Daily brief", color = p.textPrimary, style = AppFont.sm) }
        }
    }
}

@Composable
private fun FollowupChip(label: String, enabled: Boolean, onClick: () -> Unit) {
    val p = theme
    Box(
        (p.groove?.let { Modifier.darkKeycap(it) } ?: Modifier.clip(RoundedCornerShape(Radius.full)).background(p.bgSurface))
            .noRippleClickable(enabled = enabled) { onClick() }
            .padding(horizontal = Space.s3, vertical = Space.s2)
            .then(if (p.groove != null) Modifier.padding(bottom = 2.dp) else Modifier),
    ) { Text(label, color = if (p.groove != null) p.accentViolet else ChannelColor.electricBlue, style = AppFont.xs) }
}

private fun startListening(listener: ListeningManager, setListening: (Boolean) -> Unit, onResult: (String) -> Unit, onError: (String) -> Unit) {
    if (!listener.isAvailable()) { onError("Voice input isn't available on this phone."); return }
    setListening(true)
    if (listener.resolveLane() == BridgeLane.OPENAI.raw) {
        // Record now; releasing the orb stops + transcribes.
        listener.startRecording()
    } else {
        // Native live recognition returns the final text via onResult.
        listener.startNative(
            onResult = { setListening(false); onResult(it) },
            onError = { setListening(false); onError(it) },
        )
    }
}

/** Live pink audio bars from the mic level (iOS PinkAudioBars). */
@Composable
private fun PinkAudioBars(level: Float) {
    val p = theme
    val pink = p.ringColors.getOrElse(1) { p.accentViolet }
    val animated by androidx.compose.animation.core.animateFloatAsState(level, label = "level")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        repeat(12) { i ->
            val weight = 0.35f + 0.65f * kotlin.math.abs(kotlin.math.sin((i + 1) * 0.9f))
            val h = (4 + 22 * animated * weight).dp
            // Groovebox: the bars run the pastel rainbow (coral → mustard → teal → lavender).
            val bar = if (p.groove != null) p.ringColors[i * p.ringColors.size / 12] else pink
            Box(Modifier.width(3.dp).height(h).clip(RoundedCornerShape(Radius.full)).background(bar))
        }
    }
}

/** Decode a `draft_email` payload into a compose prefill (iOS ComposeDraft mapping). */
private fun decodeComposeDraft(json: String?): ComposePrefill? {
    val o = runCatching { JSONObject(json ?: return null) }.getOrNull() ?: return null
    return ComposePrefill(
        accountKey = o.optString("accountKey").ifEmpty { null },
        to = o.optString("to"),
        subject = o.optString("subject"),
        body = o.optString("body"),
    )
}

/** Decode a `draft_event` payload into an event seed (iOS eventSeed). Times are ISO-8601;
 *  falls back to "in an hour" for 30 minutes when absent/unparseable. */
private fun decodeEventDraft(json: String?): EventDraftSeed? {
    val o = runCatching { JSONObject(json ?: return null) }.getOrNull() ?: return null
    val start = com.inbox2.app.model.RelativeTime.parse(o.optString("startISO"))?.time
        ?: (System.currentTimeMillis() + 3600_000)
    val end = com.inbox2.app.model.RelativeTime.parse(o.optString("endISO"))?.time ?: (start + 1800_000)
    val names = o.optJSONArray("attendeeNames")?.let { arr ->
        (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotEmpty() } }
    } ?: emptyList()
    return EventDraftSeed(
        title = o.optString("title").ifEmpty { "Meeting" },
        startMs = start, endMs = end,
        location = o.optString("location"),
        attendees = names,
    )
}

/** Compose-canvas orb — the Android alternative to the iOS Metal sphere. */
@Composable
internal fun Orb(active: Boolean, size: androidx.compose.ui.unit.Dp, level: Float? = null) {
    val transition = rememberInfiniteTransition(label = "orb")
    val pulse by transition.animateFloat(0.92f, 1.04f,
        infiniteRepeatable(tween(if (active) 900 else 2600, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "pulse")
    // Travelling phase for the audio waveform across the planet, and a slow ring sweep.
    val phase by transition.animateFloat(0f, (2f * PI).toFloat(),
        infiniteRepeatable(tween(if (active) 1400 else 3400, easing = LinearEasing), RepeatMode.Restart), label = "phase")
    val ringSpin by transition.animateFloat(0f, 360f,
        infiniteRepeatable(tween(if (active) 6000 else 16000, easing = LinearEasing), RepeatMode.Restart), label = "ring")
    // Theme ring stops (violet/pink) for the sweep — captured here, Canvas isn't composable.
    val ring = theme.ringColors
    val groove = theme.groove
    val danger = theme.accentDanger
    Canvas(Modifier.size(size)) {
        val cx = this.size.width / 2f; val cy = this.size.height / 2f
        val center = Offset(cx, cy)
        val r = (this.size.minDimension / 2f) * pulse * 0.82f

        // Nebula glow (Groovebox: lavender)
        drawCircle(Brush.radialGradient(0f to (if (groove != null) ring[3] else ChannelColor.electricBlue).copy(alpha = 0.30f), 1f to Color.Transparent,
            center = center, radius = r * 1.7f), radius = r * 1.7f, center = center)

        // Planet body (top-left lit) + lower-right terminator for a 3D read. Groovebox
        // paints the body in the pastel rainbow under the same highlight.
        if (groove != null) {
            drawCircle(Brush.sweepGradient(ring + ring.first(), center), radius = r, center = center)
            drawCircle(Brush.radialGradient(0f to bevel(0.75f), 0.45f to Color.Transparent,
                center = Offset(cx - r * 0.32f, cy - r * 0.34f), radius = r * 1.35f), radius = r, center = center)
        } else drawCircle(Brush.radialGradient(0f to bevel(0.9f), 0.22f to ChannelColor.electricBlue, 1f to ChannelColor.electricBlueDeep,
            center = Offset(cx - r * 0.32f, cy - r * 0.34f), radius = r * 1.35f), radius = r, center = center)
        drawCircle(Brush.radialGradient(0.5f to Color.Transparent, 1f to ChannelColor.orbShadow.copy(alpha = 0.8f),
            center = Offset(cx + r * 0.34f, cy + r * 0.42f), radius = r * 1.25f), radius = r, center = center)

        // Crimson audio waveform across the planet, clipped to the sphere, tapered at the rim
        clipPath(Path().apply { addOval(Rect(cx - r, cy - r, cx + r, cy + r)) }) {
            // The waveform follows the live mic / speech level when there is one (iOS orbLevel).
            val amp = r * (level?.let { 0.10f + 0.30f * it } ?: if (active) 0.24f else 0.12f)
            val wave = Path()
            val steps = 56
            for (i in 0..steps) {
                val k = i / steps.toFloat()
                val x = cx - r + 2f * r * k
                val env = sin(PI * k).toFloat()
                val y = cy + amp * env * sin(phase + k * (4f * PI).toFloat())
                if (i == 0) wave.moveTo(x, y) else wave.lineTo(x, y)
            }
            // The waveform runs in the theme's danger accent (not a ring stop — don't
            // swap it for palette.ringColors). Groovebox: the dark keycap ink over the rainbow.
            val waveInk = groove?.chipInk ?: danger
            drawPath(wave, waveInk.copy(alpha = 0x55 / 255f), style = Stroke(width = r * 0.12f, cap = StrokeCap.Round))
            drawPath(wave, waveInk, style = Stroke(width = r * 0.05f, cap = StrokeCap.Round))
        }

        // Faint rotating ring sweep (pink → violet) just outside the planet — the theme
        // ring stops (ringColors[1] pink, ringColors[0] violet) at the original alphas.
        rotate(ringSpin, center) {
            drawCircle(Brush.sweepGradient(
                listOf(ring[1].copy(alpha = 0f), ring[1].copy(alpha = 0.6f),
                    ring[0].copy(alpha = 0f), ring[0].copy(alpha = 0.4f), ring[1].copy(alpha = 0f)),
                center = center), radius = r * 1.12f, center = center, style = Stroke(width = r * 0.02f))
        }
    }
}
