package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.border
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.BridgeCapability
import com.inbox2.app.engine.BridgeLane
import com.inbox2.app.engine.BridgeModelIds
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.VoicePrefs
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SegmentedTabs
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.insetCard
import com.inbox2.app.ui.components.noRippleClickable
import uniffi.inbox2_core.FfiLaneInfo

/**
 * On-device AI panel (iOS BridgeVoicePanel): a three-lane control per capability
 * (TTS / STT / NLU) rendered from the shared Rust model manager (`model_lanes`), with a
 * download/delete card + live progress for the free lane (driven by `model-download`
 * events) and an OpenAI key field. The manifest, availability, selection, and downloads
 * all live in the core — Android only adds this UI + the inference engines.
 */
@Composable
fun ModelPanelScreen(engine: EngineModel, onBack: () -> Unit) {
    val p = theme
    val ctx = LocalContext.current
    val prefs = remember { VoicePrefs(ctx) }
    val downloads by engine.modelDownloads.collectAsState()
    var key by remember { mutableStateOf(prefs.openAIKey) }
    val hasKey = key.isNotBlank()
    var hf by remember { mutableStateOf(prefs.hfToken) }
    // Re-push the AI/NLU config to the engine whenever a lane or the key changes, so the
    // background triage worker tracks the Bridge's model (iOS reactive aiConfigKey).
    val pushAi = { engine.setAiConfig(com.inbox2.app.engine.nluBridgeConfig(engine, prefs)) }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader("On-device AI", showBack = true, onBack = onBack)

        Text(
            "Bridge runs on your phone when it can. Pick OpenAI to use your own key.",
            color = p.textTertiary, style = AppFont.xs, modifier = Modifier.padding(horizontal = Space.s4, vertical = Space.s2),
        )

        listOf(
            BridgeCapability.TTS to "Speech",
            BridgeCapability.STT to "Listening",
            BridgeCapability.NLU to "Understanding",
        ).forEach { (cap, title) ->
            CapabilitySection(engine, prefs, cap, title, hasKey, hf.isNotBlank(), downloads, pushAi)
        }

        // OpenAI key. Save IS the test: the key is validated against OpenAI and only
        // persisted when it checks out; an invalid key surfaces inline (iOS ApiKeyField).
        val scope = rememberCoroutineScope()
        var keyStatus by remember { mutableStateOf(if (prefs.keyValidated && prefs.hasKey) "Key saved and checked. You can pick OpenAI above." else "") }
        var draftKey by remember { mutableStateOf("") }
        Text("OPENAI KEY", color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold),
            modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s3))
        Column(Modifier.insetCard().padding(Space.s3)) {
            if (hasKey) {
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text("sk-••••••••" + key.takeLast(4), color = p.textPrimary, style = AppFont.mono(13), modifier = Modifier.weight(1f))
                    Text("Remove", color = p.accentDanger, style = AppFont.xs, modifier = Modifier.noRippleClickable {
                        key = ""; prefs.openAIKey = ""; prefs.keyValidated = false; keyStatus = ""; pushAi()
                    })
                }
            } else {
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) {
                        if (draftKey.isEmpty()) Text("OpenAI API key (sk-…)", color = p.textTertiary, style = AppFont.sm)
                        BasicTextField(
                            value = draftKey, onValueChange = { draftKey = it; if (keyStatus != "Checking…") keyStatus = "" },
                            textStyle = AppFont.sm.copy(color = p.textPrimary), singleLine = true,
                            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                            cursorBrush = SolidColor(p.accentViolet), modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    if (draftKey.isNotBlank() && keyStatus != "Checking…") Text("Save", color = p.accentViolet, style = AppFont.xs,
                        modifier = Modifier.noRippleClickable {
                            keyStatus = "Checking…"
                            scope.launch {
                                val err = engine.bridgeValidateOpenAI(draftKey.trim())
                                if (err == null) {
                                    key = draftKey.trim(); prefs.openAIKey = key; prefs.keyValidated = true; draftKey = ""
                                    keyStatus = "Key saved and checked. You can pick OpenAI above."
                                    pushAi()
                                } else keyStatus = err
                            }
                        })
                }
            }
            Text(
                if (keyStatus.isNotEmpty()) keyStatus else "Optional. Without a key, everything runs on this phone.",
                color = if (keyStatus.startsWith("Key saved")) p.accentSuccess else if (keyStatus == "Checking…" || keyStatus.isEmpty()) p.textTertiary else p.accentDanger,
                style = AppFont.xs2, modifier = Modifier.padding(top = Space.s1))
        }

        JevSection(engine)

        // HuggingFace token — only the Gemma variant needs it (gated repo; its
        // download 401s without a bearer token). Everything else is ungated.
        Text("HUGGINGFACE TOKEN", color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold),
            modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s3))
        Column(Modifier.insetCard().padding(Space.s3)) {
            Box {
                if (hf.isEmpty()) Text("hf_… (only Gemma needs this)", color = p.textTertiary, style = AppFont.sm)
                BasicTextField(
                    value = hf, onValueChange = { hf = it; prefs.hfToken = it; engine.setHfToken(it.ifBlank { null }) },
                    textStyle = AppFont.sm.copy(color = p.textPrimary), singleLine = true,
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                    cursorBrush = SolidColor(p.accentViolet), modifier = Modifier.fillMaxWidth(),
                )
            }
            Text(
                if (hf.isBlank()) "Accept the Gemma license at huggingface.co, then paste your token here."
                else "Saved on this phone. You can download Gemma now.",
                color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(top = Space.s1),
            )
        }
        Spacer(Modifier.height(60.dp))
    }
}

/**
 * "Jev by TypeSafe" — the user's own key for local-channel triage (label, priority,
 * Space). Test & save validates with one real call, stores it in [SecureStore] and
 * pushes it to the engine; Remove clears both (docs/Triage.md "Local channels").
 */
@Composable
private fun JevSection(engine: EngineModel) {
    val p = theme
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val triage by engine.triage.collectAsState()
    var saved by remember { mutableStateOf(false) }
    var key by remember { mutableStateOf("") }
    var status by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        saved = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.inbox2.app.SecureStore.get(ctx, com.inbox2.app.SecureStore.TYPESAFE_KEY) != null
        }
    }

    Text("JEV BY TYPESAFE", color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold),
        modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s3))
    Column(Modifier.insetCard().padding(Space.s3)) {
        if (saved) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val (label, color) = when (triage.jevStatus) {
                    "ok" -> "Key saved · triage active" to p.accentSuccess
                    "unauthorized" -> "TypeSafe didn't accept this key · paste a new one" to p.accentDanger
                    else -> "Key saved" to p.textSecondary
                }
                Text(label, color = color, style = AppFont.sm, modifier = Modifier.weight(1f))
                Text("Remove", color = p.accentDanger, style = AppFont.xs,
                    modifier = Modifier.noRippleClickable {
                        scope.launch {
                            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                com.inbox2.app.SecureStore.set(ctx, com.inbox2.app.SecureStore.TYPESAFE_KEY, null)
                            }
                            engine.setJevKey(null)
                            saved = false; status = ""
                        }
                    })
            }
        }
        if (!saved || triage.jevStatus == "unauthorized") {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = if (saved) Space.s2 else 0.dp)) {
                Box(Modifier.weight(1f)) {
                    if (key.isEmpty()) Text("TypeSafe API key", color = p.textTertiary, style = AppFont.sm)
                    BasicTextField(
                        value = key, onValueChange = { key = it; status = "" },
                        textStyle = AppFont.sm.copy(color = p.textPrimary), singleLine = true,
                        visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
                        cursorBrush = SolidColor(p.accentViolet), modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (key.isNotBlank() && !busy) Text("Test & save", color = p.accentViolet, style = AppFont.xs,
                    modifier = Modifier.noRippleClickable {
                        busy = true; status = "Checking…"
                        scope.launch {
                            val err = engine.validateJevKey(key)
                            if (err == null) {
                                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                    com.inbox2.app.SecureStore.set(ctx, com.inbox2.app.SecureStore.TYPESAFE_KEY, key.trim())
                                }
                                engine.setJevKey(key)
                                saved = true; key = ""; status = ""
                            } else status = err
                            busy = false
                        }
                    })
            }
            if (status.isNotEmpty()) Text(status,
                color = if (status == "Checking…") p.textTertiary else p.accentDanger,
                style = AppFont.xs2, modifier = Modifier.padding(top = Space.s1))
        }
        Text(
            "Jev labels, ranks and files your mail into Spaces. We send up to 12 KB of each thread to TypeSafe. They don't train on it. Without a key, simple rules label your mail.",
            color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(top = Space.s2),
        )
    }
}

@Composable
private fun CapabilitySection(
    engine: EngineModel, prefs: VoicePrefs, cap: BridgeCapability, title: String,
    hasKey: Boolean, hasHfToken: Boolean, downloads: Map<String, com.inbox2.app.engine.ModelDownload>,
    onConfigChanged: () -> Unit,
) {
    val p = theme
    var lanePref by remember { mutableStateOf(prefs.lane(cap)) }
    val lanes = remember(hasKey, downloads) { engine.modelLanes(cap.raw, hasKey) }
    val effective = remember(lanePref, hasKey, downloads) { engine.effectiveLane(cap.raw, lanePref, hasKey) }

    // Only offer lanes the platform actually has (native may be absent on Android).
    val laneOptions = lanes.map { it.lane }.distinct()
    val labels = mapOf(BridgeLane.NATIVE.raw to "Device", BridgeLane.FREE.raw to "Free", BridgeLane.OPENAI.raw to "OpenAI")

    Text(title.uppercase(), color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold),
        modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s3))

    Column(Modifier.insetCard().padding(Space.s3)) {
        if (laneOptions.size > 1) {
            // Unavailable lanes are dimmed and untappable, with the core's reason shown in
            // amber below (iOS lanePills) — "why is Device greyed out?" is the common question.
            val availability = laneOptions.associateWith { lane -> lanes.firstOrNull { it.lane == lane }?.available ?: true }
            LanePills(laneOptions.map { it to (labels[it] ?: it) }, lanePref.raw, availability) { raw ->
                lanePref = BridgeLane.entries.firstOrNull { it.raw == raw } ?: lanePref
                prefs.setLane(cap, lanePref)
                if (cap == BridgeCapability.NLU) onConfigChanged()
            }
            lanes.firstOrNull { !it.available && it.reason != null }?.reason?.let { reason ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = Space.s2)) {
                    Icon(SfIcon.vector("info.circle"), null, tint = p.accentAmber, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(Space.s1))
                    Text(reason, color = p.accentAmber, style = AppFont.xs2)
                }
            }
        }
        Text("Using: ${labels[effective] ?: effective}", color = p.textTertiary, style = AppFont.xs2,
            modifier = Modifier.padding(top = Space.s2))

        // OpenAI TTS voice picker (shown when TTS routes to OpenAI).
        if (cap == BridgeCapability.TTS && effective == BridgeLane.OPENAI.raw) {
            var voice by remember { mutableStateOf(prefs.ttsVoice) }
            var menu by remember { mutableStateOf(false) }
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, modifier = Modifier.padding(top = Space.s2)) {
                Text("Voice", color = p.textTertiary, style = AppFont.xs, modifier = Modifier.weight(1f))
                Box {
                    Text(voice.replaceFirstChar { it.uppercase() }, color = p.accentViolet, style = AppFont.xs,
                        modifier = Modifier.noRippleClickable { menu = true })
                    androidx.compose.material3.DropdownMenu(menu, onDismissRequest = { menu = false }) {
                        VoicePrefs.OPENAI_VOICES.forEach { v ->
                            androidx.compose.material3.DropdownMenuItem(
                                text = { Text(v.replaceFirstChar { it.uppercase() }, color = p.textPrimary, style = AppFont.sm) },
                                onClick = { voice = v; prefs.ttsVoice = v; menu = false })
                        }
                    }
                }
            }
            // The read-aloud surface's own voice — "Same as Bridge" leads (iOS readerVoiceCard).
            var readerVoice by remember { mutableStateOf(prefs.readerTtsVoice) }
            var readerMenu by remember { mutableStateOf(false) }
            Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, modifier = Modifier.padding(top = Space.s2)) {
                Text("Read-aloud voice", color = p.textTertiary, style = AppFont.xs, modifier = Modifier.weight(1f))
                Box {
                    Text(readerVoice?.replaceFirstChar { it.uppercase() } ?: "Same as Bridge", color = p.accentViolet, style = AppFont.xs,
                        modifier = Modifier.noRippleClickable { readerMenu = true })
                    androidx.compose.material3.DropdownMenu(readerMenu, onDismissRequest = { readerMenu = false }) {
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Same as Bridge", color = p.textPrimary, style = AppFont.sm) },
                            onClick = { readerVoice = null; prefs.readerTtsVoice = null; readerMenu = false })
                        androidx.compose.material3.HorizontalDivider()
                        VoicePrefs.OPENAI_VOICES.forEach { v ->
                            androidx.compose.material3.DropdownMenuItem(
                                text = { Text(v.replaceFirstChar { it.uppercase() }, color = p.textPrimary, style = AppFont.sm) },
                                onClick = { readerVoice = v; prefs.readerTtsVoice = v; readerMenu = false })
                        }
                    }
                }
            }
        }

        // Native (on-device) TTS voice picker — Android's shipped native lane, also the
        // free lane's fallback engine (iOS appleVoicePicker).
        if (cap == BridgeCapability.TTS && (effective == BridgeLane.NATIVE.raw || effective == BridgeLane.FREE.raw)) {
            val nativeVoices = rememberNativeVoices()
            if (nativeVoices.isNotEmpty()) {
                var sel by remember { mutableStateOf(prefs.nativeVoiceId) }
                var menu by remember { mutableStateOf(false) }
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, modifier = Modifier.padding(top = Space.s2)) {
                    Text("Voice", color = p.textTertiary, style = AppFont.xs, modifier = Modifier.weight(1f))
                    Box {
                        val current = nativeVoices.firstOrNull { it.id == sel }?.label ?: "Default"
                        Text(current, color = p.accentViolet, style = AppFont.xs,
                            modifier = Modifier.noRippleClickable { menu = true })
                        androidx.compose.material3.DropdownMenu(menu, onDismissRequest = { menu = false }) {
                            androidx.compose.material3.DropdownMenuItem(
                                text = { Text("Default", color = p.textPrimary, style = AppFont.sm) },
                                onClick = { sel = ""; prefs.nativeVoiceId = ""; menu = false })
                            nativeVoices.forEach { v ->
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text(v.label, color = p.textPrimary, style = AppFont.sm) },
                                    onClick = { sel = v.id; prefs.nativeVoiceId = v.id; menu = false })
                            }
                        }
                    }
                }
                var readerSel by remember { mutableStateOf(prefs.readerNativeVoiceId) }
                var readerMenu by remember { mutableStateOf(false) }
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically, modifier = Modifier.padding(top = Space.s2)) {
                    Text("Read-aloud voice", color = p.textTertiary, style = AppFont.xs, modifier = Modifier.weight(1f))
                    Box {
                        val current = when (readerSel) {
                            null -> "Same as Bridge"
                            "" -> "Default"
                            else -> nativeVoices.firstOrNull { it.id == readerSel }?.label ?: "Default"
                        }
                        Text(current, color = p.accentViolet, style = AppFont.xs, modifier = Modifier.noRippleClickable { readerMenu = true })
                        androidx.compose.material3.DropdownMenu(readerMenu, onDismissRequest = { readerMenu = false }) {
                            androidx.compose.material3.DropdownMenuItem(
                                text = { Text("Same as Bridge", color = p.textPrimary, style = AppFont.sm) },
                                onClick = { readerSel = null; prefs.readerNativeVoiceId = null; readerMenu = false })
                            androidx.compose.material3.HorizontalDivider()
                            androidx.compose.material3.DropdownMenuItem(
                                text = { Text("Default", color = p.textPrimary, style = AppFont.sm) },
                                onClick = { readerSel = ""; prefs.readerNativeVoiceId = ""; readerMenu = false })
                            nativeVoices.forEach { v ->
                                androidx.compose.material3.DropdownMenuItem(
                                    text = { Text(v.label, color = p.textPrimary, style = AppFont.sm) },
                                    onClick = { readerSel = v.id; prefs.readerNativeVoiceId = v.id; readerMenu = false })
                            }
                        }
                    }
                }
            }
        }

        // Free-lane download/delete card. NLU offers two variants (Qwen / Gemma)
        // with a picker — BridgeLLM runs the selected one; other capabilities
        // have a single free model. Metadata mirrors the core manifest.
        if (cap == BridgeCapability.NLU) {
            var freeModel by remember { mutableStateOf(prefs.freeNluModel) }
            listOf(
                Triple(BridgeModelIds.QWEN, "Qwen", "Best quality · multilingual · 1.6 GB"),
                Triple(BridgeModelIds.GEMMA, "Gemma", "Faster · English-only · 722 MB"),
            ).forEach { (id, name, detail) ->
                NluVariantCard(
                    engine, id, name, detail, downloads[id], hasHfToken,
                    selected = freeModel == id,
                    onSelect = {
                        freeModel = id; prefs.freeNluModel = id
                        // The pick IS the lane choice (iOS variant pills): run it, and let the
                        // background triage worker track the same model.
                        lanePref = BridgeLane.FREE; prefs.setLane(cap, BridgeLane.FREE)
                        onConfigChanged()
                    },
                )
            }
        } else {
            lanes.firstOrNull { it.lane == BridgeLane.FREE.raw }?.let { free ->
                FreeLaneCard(engine, free, downloads[free.id])
            }
        }
    }
}

/**
 * One selectable NLU free-lane variant: a radio (which model the lane runs), name +
 * trade-off, and the same download/progress/delete control as FreeLaneCard. Gemma's
 * download is gated on the HuggingFace token (gated repo).
 */
@Composable
private fun NluVariantCard(
    engine: EngineModel, id: String, name: String, detail: String,
    dl: com.inbox2.app.engine.ModelDownload?, hasHfToken: Boolean,
    selected: Boolean, onSelect: () -> Unit,
) {
    val p = theme
    val installed = dl?.isInstalled ?: (engine.modelPath(id) != null)
    val active = dl?.isActive ?: false
    Column(
        Modifier.fillMaxWidth().padding(top = Space.s2)
            .clip(RoundedCornerShape(Radius.md)).background(p.bgElevated)
            .noRippleClickable { onSelect() }
            .padding(Space.s2),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(SfIcon.vector(if (selected) "checkmark.circle.fill" else "circle"), null,
                tint = if (selected) p.accentViolet else p.textTertiary, modifier = Modifier.size(16.dp))
            Column(Modifier.weight(1f).padding(start = Space.s2)) {
                Text(name, color = p.textPrimary, style = AppFont.xs, maxLines = 1)
                Text(detail, color = p.textTertiary, style = AppFont.xs2)
            }
            when {
                // Gemma is gated — disable the download until a HF token is set.
                id == BridgeModelIds.GEMMA && !installed && !active && !hasHfToken ->
                    Text("Needs token", color = p.textMuted, style = AppFont.xs)
                active -> Text("${((dl?.fraction ?: 0f) * 100).toInt()}%", color = p.accentViolet, style = AppFont.xs)
                installed -> Text("Delete", color = p.accentDanger, style = AppFont.xs,
                    modifier = Modifier.noRippleClickable { engine.deleteModel(id) })
                else -> Text("Download", color = p.accentViolet, style = AppFont.xs,
                    modifier = Modifier.noRippleClickable { engine.downloadModel(id) })
            }
        }
        if (active) {
            LinearProgressIndicator(
                progress = { dl?.fraction ?: 0f },
                modifier = Modifier.fillMaxWidth().padding(top = Space.s1),
                color = p.accentViolet, trackColor = p.bgInput,
            )
        }
        dl?.error?.let { Text(it, color = p.accentDanger, style = AppFont.xs2, modifier = Modifier.padding(top = 2.dp)) }
        if (selected && !installed) {
            Text("Not downloaded yet. Bridge uses the other one until then.",
                color = p.accentAmber, style = AppFont.xs2, modifier = Modifier.padding(top = 2.dp))
        }
    }
}

@Composable
private fun FreeLaneCard(engine: EngineModel, lane: FfiLaneInfo, dl: com.inbox2.app.engine.ModelDownload?) {
    val p = theme
    val installed = dl?.isInstalled ?: (engine.modelPath(lane.id) != null)
    val active = dl?.isActive ?: false
    Column(Modifier.fillMaxWidth().padding(top = Space.s2).clip(RoundedCornerShape(Radius.md)).background(p.bgElevated).padding(Space.s2)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(modelShortName(lane.id), color = p.textPrimary, style = AppFont.xs, maxLines = 1)
                val size = if (lane.totalBytes > 0u) "%.0f MB".format(lane.totalBytes.toDouble() / 1_000_000) else ""
                Text(listOf(size, lane.license).filter { it.isNotEmpty() }.joinToString(" · "), color = p.textTertiary, style = AppFont.xs2)
            }
            when {
                active -> Text("${((dl?.fraction ?: 0f) * 100).toInt()}%", color = p.accentViolet, style = AppFont.xs)
                installed -> Text("Delete", color = p.accentDanger, style = AppFont.xs,
                    modifier = Modifier.noRippleClickable { engine.deleteModel(lane.id) })
                else -> Text("Download", color = p.accentViolet, style = AppFont.xs,
                    modifier = Modifier.noRippleClickable { engine.downloadModel(lane.id) })
            }
        }
        if (active) {
            LinearProgressIndicator(
                progress = { dl?.fraction ?: 0f },
                modifier = Modifier.fillMaxWidth().padding(top = Space.s1),
                color = p.accentViolet, trackColor = p.bgInput,
            )
        }
        dl?.error?.let { Text(it, color = p.accentDanger, style = AppFont.xs2, modifier = Modifier.padding(top = 2.dp)) }
    }
}

/** A selectable on-device TTS voice (native lane). */
private data class NativeVoiceOption(val id: String, val label: String)

/** Enumerate the device's installed TTS voices for the current UI language — spins up a
 *  short-lived TextToSpeech to read `voices`, then shuts it down (iOS availableAppleVoices). */
@Composable
private fun rememberNativeVoices(): List<NativeVoiceOption> {
    val ctx = LocalContext.current
    var voices by remember { mutableStateOf<List<NativeVoiceOption>>(emptyList()) }
    DisposableEffect(Unit) {
        var tts: android.speech.tts.TextToSpeech? = null
        tts = android.speech.tts.TextToSpeech(ctx.applicationContext) { status ->
            if (status == android.speech.tts.TextToSpeech.SUCCESS) {
                val lang = java.util.Locale.getDefault().language
                voices = runCatching {
                    (tts?.voices ?: emptySet()).asSequence()
                        .filter { it.locale.language == lang && !it.isNetworkConnectionRequired }
                        .filter { android.speech.tts.TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in (it.features ?: emptySet()) }
                        .sortedBy { it.name }
                        .map { v ->
                            val where = v.locale.displayCountry.ifEmpty { v.locale.displayLanguage }
                            val tail = v.name.substringAfterLast('-').ifEmpty { v.name }.take(16)
                            NativeVoiceOption(v.name, "$where · $tail")
                        }
                        .toList()
                }.getOrDefault(emptyList())
            }
        }
        onDispose { runCatching { tts?.shutdown() } }
    }
    return voices
}

/** "kokoro-82m-int8" / "vendor/whisper-base" → "Kokoro 82m int8" (iOS modelShortName). */
private fun modelShortName(id: String): String =
    id.substringAfterLast('/').split('-', '_').filter { it.isNotEmpty() }
        .joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }

/** Lane pills: the active one raised, unavailable ones dimmed + untappable. */
@Composable
private fun LanePills(options: List<Pair<String, String>>, selected: String, availability: Map<String, Boolean>, onSelect: (String) -> Unit) {
    val p = theme
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
        options.forEach { (raw, label) ->
            val available = availability[raw] ?: true
            val active = raw == selected
            Text(
                label, color = if (active) p.textPrimary else p.textTertiary,
                style = AppFont.ui(13, if (active) FontWeight.SemiBold else FontWeight.Medium),
                modifier = Modifier.alpha(if (available) 1f else 0.45f)
                    .clip(RoundedCornerShape(Radius.full))
                    .background(if (active) p.bgElevated else androidx.compose.ui.graphics.Color.Transparent)
                    .then(if (active) Modifier.border(1.dp, p.borderStrong, RoundedCornerShape(Radius.full)) else Modifier)
                    .noRippleClickable(enabled = available) { onSelect(raw) }
                    .padding(horizontal = Space.s3, vertical = Space.s2),
            )
        }
    }
}
