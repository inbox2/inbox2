package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.MarkReadMode
import com.inbox2.app.engine.MarkReadPrefs
import com.inbox2.app.model.Contact
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.AvatarRing
import com.inbox2.app.ui.components.EmptyState
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.insetCard
import com.inbox2.app.ui.components.noRippleClickable
import androidx.compose.ui.text.withStyle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Preferences (iOS PreferencesPanel): notifications + the mark-as-read mode + dwell delay. */
@Composable
fun PreferencesScreen(onBack: () -> Unit) {
    val p = theme
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val prefs = remember { MarkReadPrefs(ctx) }
    var mode by remember { mutableStateOf(prefs.mode) }
    var delay by remember { mutableStateOf(prefs.delaySeconds) }
    var notifyNewMail by remember { mutableStateOf(com.inbox2.app.notify.NotificationHelper.newMailEnabled(ctx)) }
    var notifySound by remember { mutableStateOf(com.inbox2.app.notify.NotificationHelper.soundEnabled(ctx)) }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader("Preferences", showBack = true, onBack = onBack)
        Text("NOTIFICATIONS", color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold),
            modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s2))
        ToggleRow("New mail", notifyNewMail) { on -> notifyNewMail = on; com.inbox2.app.notify.NotificationHelper.setNewMailEnabled(ctx, on) }
        ToggleRow("Sound", notifySound) { on -> notifySound = on; com.inbox2.app.notify.NotificationHelper.setSoundEnabled(ctx, on) }
        // Meeting alarms (iOS MeetingAlarms): opt-in, lead time, a test, and — because the
        // feature fails silently by definition — whether the OS is currently letting it through.
        val alarms = com.inbox2.app.notify.MeetingAlarms
        var meetingAlarm by remember { mutableStateOf(alarms.enabled(ctx)) }
        var lead by remember { mutableStateOf(alarms.leadMinutes(ctx)) }
        var alarmStatus by remember { mutableStateOf(alarms.systemStatus(ctx)) }
        val engine = com.inbox2.app.engine.EngineModel.peek()
        val scope = androidx.compose.runtime.rememberCoroutineScope()
        ToggleRow("Meeting alarm", meetingAlarm) { on ->
            meetingAlarm = on; alarms.setEnabled(ctx, on); alarmStatus = alarms.systemStatus(ctx)
            if (on) engine?.let { e -> scope.launch { alarms.reconcile(ctx, e, force = true) } }
        }
        if (meetingAlarm) {
            var leadMenu by remember { mutableStateOf(false) }
            Row(Modifier.fillMaxWidth().noRippleClickable { leadMenu = true }.padding(horizontal = Space.s5, vertical = Space.s3),
                verticalAlignment = Alignment.CenterVertically) {
                Text("Alarm at", color = p.textSecondary, style = AppFont.ui(16), modifier = Modifier.weight(1f))
                Text("$lead min before", color = p.textTertiary, style = AppFont.body)
                Spacer(Modifier.width(Space.s2))
                Icon(SfIcon.vector("chevron.up.chevron.down"), null, tint = p.textMuted, modifier = Modifier.size(14.dp))
                androidx.compose.material3.DropdownMenu(leadMenu, onDismissRequest = { leadMenu = false }) {
                    alarms.LEAD_CHOICES.forEach { m ->
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("$m min before", color = p.textPrimary, style = AppFont.sm) },
                            onClick = {
                                lead = m; alarms.setLeadMinutes(ctx, m); leadMenu = false
                                engine?.let { e -> scope.launch { alarms.reconcile(ctx, e, force = true) } }
                            })
                    }
                }
            }
            Row(Modifier.fillMaxWidth().noRippleClickable { alarms.fireTest(ctx); alarmStatus = alarms.systemStatus(ctx) }
                .padding(horizontal = Space.s5, vertical = Space.s3), verticalAlignment = Alignment.CenterVertically) {
                Text("Test alarm", color = p.textSecondary, style = AppFont.ui(16), modifier = Modifier.weight(1f))
                Text("in 5s", color = p.textTertiary, style = AppFont.body)
                Spacer(Modifier.width(Space.s2))
                Icon(SfIcon.vector("bell.badge"), null, tint = p.accentViolet, modifier = Modifier.size(16.dp))
            }
        }
        Text("Rings for 25 seconds before each meeting, even in Do Not Disturb when inbox2 is allowed there. The alarm volume applies.",
            color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2))
        if (meetingAlarm) alarmStatus?.let {
            Text(it, color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2))
        }
        Text("MARK AS READ", color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold),
            modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s2))
        MarkReadMode.entries.forEach { m ->
            Row(
                Modifier.fillMaxWidth().noRippleClickable { mode = m; prefs.mode = m }
                    .padding(horizontal = Space.s4, vertical = Space.s3),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(m.title, color = p.textPrimary, style = AppFont.body)
                    Text(m.detail, color = p.textTertiary, style = AppFont.xs)
                }
                if (mode == m) Icon(SfIcon.vector("checkmark"), null, tint = p.accentViolet, modifier = Modifier.size(20.dp))
            }
        }
        if (mode == MarkReadMode.DELAY) {
            Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4, vertical = Space.s3), verticalAlignment = Alignment.CenterVertically) {
                Text("Delay", color = p.textPrimary, style = AppFont.body, modifier = Modifier.weight(1f))
                Stepper("−") { if (delay > 1) { delay--; prefs.delaySeconds = delay } }
                Text("${delay}s", color = p.textPrimary, style = AppFont.md, modifier = Modifier.padding(horizontal = Space.s3))
                Stepper("+") { if (delay < 30) { delay++; prefs.delaySeconds = delay } }
            }
        }
    }
}

/** A labelled setting toggle row (iOS Toggle) — full-width label + a violet-tinted Switch. */
@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    val p = theme
    Row(
        Modifier.fillMaxWidth().noRippleClickable { onChange(!checked) }
            .padding(horizontal = Space.s5, vertical = Space.s2).heightIn(min = 52.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = p.textSecondary, style = AppFont.ui(16), modifier = Modifier.weight(1f))
        androidx.compose.material3.Switch(
            checked = checked, onCheckedChange = onChange,
            colors = if (p.groove != null) com.inbox2.app.ui.components.inboxSwitchColors()
            else androidx.compose.material3.SwitchDefaults.colors(
                checkedThumbColor = androidx.compose.ui.graphics.Color.White,
                checkedTrackColor = p.accentViolet,
                uncheckedTrackColor = p.bgElevated,
                uncheckedBorderColor = p.borderStrong,
            ),
        )
    }
}

@Composable
private fun Stepper(label: String, onClick: () -> Unit) {
    val p = theme
    Box(Modifier.size(32.dp).clip(RoundedCornerShape(Radius.md)).background(p.bgElevated)
        .noRippleClickable { onClick() },
        contentAlignment = Alignment.Center) { Text(label, color = p.textPrimary, style = AppFont.title3) }
}

/** Contacts (iOS EnrichmentPanel): frequency-ranked recipients derived from mail. */
@Composable
fun ContactsScreen(engine: EngineModel, onBack: () -> Unit) {
    val p = theme
    var contacts by remember { mutableStateOf<List<Contact>>(emptyList()) }
    LaunchedEffect(Unit) { contacts = withContext(Dispatchers.IO) { engine.store.contacts() } }
    Column(Modifier.fillMaxSize().background(p.bgBase)) {
        ScreenHeader("Contacts", showBack = true, onBack = onBack)
        if (contacts.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(bottom = 60.dp), contentAlignment = Alignment.Center) {
                EmptyState("person.2", "No contacts yet", "People you email most")
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                items(contacts.size) { i ->
                    val c = contacts[i]
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s3)) {
                        AvatarRing((c.name.ifEmpty { c.email }).take(2).uppercase(), 36.dp, com.inbox2.app.model.MailAddress.seed(c.email))
                        Column(Modifier.weight(1f)) {
                            Text(c.name.ifEmpty { c.email }, color = p.textPrimary, style = AppFont.sm, maxLines = 1)
                            if (c.name.isNotEmpty()) Text(c.email, color = p.textTertiary, style = AppFont.xs, maxLines = 1)
                        }
                        Text("${c.total}", color = p.textTertiary, style = AppFont.xs2)
                    }
                }
            }
        }
    }
}

/** App logs (iOS AppLogsPanel): the app's own logcat for the inbox2 tags. */
@Composable
fun AppLogsScreen(onBack: () -> Unit) {
    val p = theme
    val clipboard = LocalClipboardManager.current
    var log by remember { mutableStateOf("Loading…") }
    suspend fun load() {
        log = withContext(Dispatchers.IO) {
            runCatching {
                ProcessBuilder("logcat", "-d", "-t", "500",
                    "com.inbox2.core:V", "com.inbox2.engine:V", "com.inbox2.store:V", "*:S")
                    .redirectErrorStream(true).start().inputStream.bufferedReader().readText()
                    // Newest first, so the most recent activity is at the top.
                    .trimEnd().lines().asReversed().joinToString("\n")
            }.getOrDefault("(logcat unavailable)").ifBlank { "(no logs yet)" }
        }
    }
    LaunchedEffect(Unit) { load() }
    val scope = rememberCoroutineScope()
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) { if (copied) { kotlinx.coroutines.delay(1500); copied = false } }
    Column(Modifier.fillMaxSize().background(p.bgBase)) {
        ScreenHeader("App logs", showBack = true, onBack = onBack) {
            // Copy (a tick confirms), then refresh — iOS AppLogsPanel.
            Icon(SfIcon.vector(if (copied) "checkmark" else "doc.on.doc"), "Copy", tint = if (copied) p.accentTeal else p.accentViolet,
                modifier = Modifier.size(18.dp).noRippleClickable { clipboard.setText(AnnotatedString(log)); copied = true })
            Spacer(Modifier.width(Space.s4))
            Icon(SfIcon.vector("arrow.clockwise"), "Refresh", tint = p.accentViolet,
                modifier = Modifier.size(18.dp).noRippleClickable { log = "Loading…"; scope.launch { load() } })
        }
        // Desktop-style coloured lines: muted time, bold level in its colour, teal tag,
        // secondary message. logcat threadtime: "MM-DD HH:MM:SS.mmm  PID  TID L TAG: msg".
        val line = Regex("""^(\S+ \S+)\s+\d+\s+\d+\s+([VDIWEF])\s+([^:]+):\s?(.*)$""")
        val styled = remember(log) {
            androidx.compose.ui.text.buildAnnotatedString {
                log.lines().forEach { raw ->
                    val m = line.find(raw)
                    if (m == null) { append(raw); append("\n"); return@forEach }
                    val (time, lvl, tag, msg) = m.destructured
                    val levelColor = when (lvl) { "E", "F" -> p.statusDangerText; "W" -> p.statusWarnText; "D", "V" -> p.statusDebugText; else -> p.statusInfoText }
                    withStyle(androidx.compose.ui.text.SpanStyle(color = p.textMuted)) { append(time.substringAfter(' ').substringBefore('.')); append(" ") }
                    withStyle(androidx.compose.ui.text.SpanStyle(color = levelColor, fontWeight = FontWeight.Bold)) {
                        append(when (lvl) { "E" -> "ERROR"; "F" -> "FATAL"; "W" -> "WARN"; "D" -> "DEBUG"; "V" -> "VERBOSE"; else -> "INFO" })
                    }
                    append("  ")
                    withStyle(androidx.compose.ui.text.SpanStyle(color = p.accentTeal)) { append("[${tag.trim()}] ") }
                    withStyle(androidx.compose.ui.text.SpanStyle(color = p.textSecondary)) { append(msg) }
                    append("\n")
                }
            }
        }
        Text(styled, style = AppFont.mono(10),
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Space.s3))
    }
}

/** Developer diagnostics (iOS DevModePanel): engine status, data dir, version. */
@Composable
fun DevScreen(engine: EngineModel, onBack: () -> Unit, themeManager: com.inbox2.app.theme.ThemeManager? = null) {
    val p = theme
    val status by engine.status.collectAsState()
    // The token/primitive gallery (iOS StyleGuideView) — pushed like the prompt editor.
    var styleGuide by remember { mutableStateOf(false) }
    if (styleGuide && themeManager != null) { StyleGuideScreen(themeManager, onBack = { styleGuide = false }); return }
    // Prompt templates (dev editor): per-section list + a pushed editor (iOS
    // PromptTemplatesView). Sections rebuild + validate through the core.
    var sections by remember { mutableStateOf(engine.promptSections()) }
    val defaults = remember { engine.defaultPromptSections() }
    var editingIndex by remember { mutableStateOf<Int?>(null) }

    editingIndex?.let { idx ->
        val section = sections[idx]
        PromptSectionEditor(
            sectionKey = section.key,
            text = section.text,
            defaultText = defaults[section.key] ?: "",
            onBack = { editingIndex = null },
            onApply = { newText ->
                val updated = sections.toMutableList()
                    .apply { this[idx] = uniffi.inbox2_core.FfiPromptSection(section.key, newText) }
                val err = engine.applyPromptSections(updated)
                if (err == null) sections = updated
                err
            },
        )
        return
    }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader("Developer", showBack = true, onBack = onBack)
        Column(Modifier.padding(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
            DiagRow("Engine", status)
            DiagRow("Data dir", engine.dataDir.path)
            DiagRow("Version", com.inbox2.app.BuildConfig.VERSION_NAME)
            DiagRow("App id", com.inbox2.app.BuildConfig.APPLICATION_ID)
        }
        if (themeManager != null) Row(
            Modifier.fillMaxWidth().noRippleClickable { styleGuide = true }.padding(horizontal = Space.s5, vertical = Space.s3),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Style guide", color = p.textSecondary, style = AppFont.ui(16), modifier = Modifier.weight(1f))
            Icon(SfIcon.vector("chevron.right"), null, tint = p.textMuted, modifier = Modifier.size(16.dp))
        }

        Text("PROMPT TEMPLATES", color = p.textTertiary, style = AppFont.ui(12, FontWeight.SemiBold),
            modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s3))
        Column(Modifier.insetCard()) {
            sections.forEachIndexed { i, s ->
                Row(
                    Modifier.fillMaxWidth()
                        .noRippleClickable { editingIndex = i }
                        .padding(horizontal = Space.s3, vertical = Space.s3),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(promptSectionTitle(s.key), color = p.textSecondary, style = AppFont.sm, modifier = Modifier.weight(1f))
                    if (defaults[s.key] != null && defaults[s.key] != s.text) {
                        Text("edited", color = p.accentViolet, style = AppFont.xs2,
                            modifier = Modifier.padding(end = Space.s2))
                    }
                    Icon(SfIcon.vector("chevron.right"), null, tint = p.textMuted, modifier = Modifier.size(16.dp))
                }
            }
        }
        Text(
            "Your edits change Bridge and summaries on this phone right away. Edit triage labels under Triage & sync.",
            color = p.textTertiary, style = AppFont.xs2,
            modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2),
        )
        Spacer(Modifier.height(60.dp))
    }
}

/** Display title for a prompt section's TOML key. */
private fun promptSectionTitle(key: String): String = when (key) {
    "chat" -> "Voice chat"
    "brief" -> "Daily brief"
    "tomorrow" -> "Tomorrow preview"
    "week" -> "Week ahead"
    "draft_reply" -> "Draft reply"
    "summary" -> "Summaries"
    "openai" -> "OpenAI model"
    else -> key
}

/**
 * One prompt section's full-screen editor (iOS PromptSectionEditor): monospaced
 * text, Save & apply + Reset to default, inline validation errors from the core
 * (nothing installs or persists until the edit passes).
 */
@Composable
private fun PromptSectionEditor(
    sectionKey: String,
    text: String,
    defaultText: String,
    onBack: () -> Unit,
    onApply: (String) -> String?,
) {
    val p = theme
    var draft by remember { mutableStateOf(text) }
    var saved by remember { mutableStateOf(text) }
    var error by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    val dirty = draft != saved

    androidx.activity.compose.BackHandler { onBack() }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader(promptSectionTitle(sectionKey), showBack = true, onBack = onBack)

        Column(Modifier.padding(horizontal = Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
            Box(Modifier.fillMaxWidth().insetCard().padding(Space.s3)) {
                androidx.compose.foundation.text.BasicTextField(
                    value = draft,
                    onValueChange = { draft = it; error = null; notice = null },
                    textStyle = AppFont.mono(12).copy(color = p.textPrimary),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(p.accentViolet),
                    modifier = Modifier.fillMaxWidth().heightIn(min = if (sectionKey == "openai") 24.dp else 360.dp),
                )
            }

            error?.let { Text(it, color = p.accentDanger, style = AppFont.xs2) }
            notice?.let { Text(it, color = p.accentSuccess, style = AppFont.xs2) }

            Row(horizontalArrangement = Arrangement.spacedBy(Space.s4)) {
                Text("Save & apply",
                    color = if (dirty) p.accentViolet else p.textMuted, style = AppFont.md,
                    modifier = Modifier.noRippleClickable(enabled = dirty) {
                        notice = null
                        val err = onApply(draft)
                        if (err != null) { error = err } else {
                            error = null; saved = draft
                            notice = if (draft == defaultText) "Back to the default." else "Saved on this phone."
                        }
                    })
                if (draft != defaultText) {
                    Text("Reset to default", color = p.accentAmber, style = AppFont.md,
                        modifier = Modifier.noRippleClickable {
                            draft = defaultText
                            val err = onApply(defaultText)
                            if (err != null) { error = err } else {
                                error = null; saved = defaultText
                                notice = "Back to the default."
                            }
                        })
                }
            }
            Spacer(Modifier.height(60.dp))
        }
    }
}

@Composable
private fun DiagRow(label: String, value: String) {
    val p = theme
    Column {
        Text(label, color = p.textTertiary, style = AppFont.xs2)
        Text(value, color = p.textPrimary, style = AppFont.mono(12))
    }
}
