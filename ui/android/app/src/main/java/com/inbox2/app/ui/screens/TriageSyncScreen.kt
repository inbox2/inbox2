package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Switch
import androidx.compose.ui.graphics.SolidColor
import com.inbox2.app.engine.TriageLabelDef
import com.inbox2.app.theme.Radius
import com.inbox2.app.ui.components.PillButton
import kotlinx.coroutines.launch
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.ProcessingWindow
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.insetCard
import com.inbox2.app.ui.components.noRippleClickable

/**
 * Triage & sync panel (iOS TriageSyncPanel): the background classifier/summarizer
 * progress, the processing-window selector, and the local triage labels editor
 * (built-ins: enable + description/not-for; custom: add/edit/delete — docs/Triage.md).
 * Backed by the core FFI get/setProcessingWindow, triageProgress, get/setTriageLabels
 * and the `triage-progress` event.
 */
@Composable
fun TriageSyncScreen(engine: EngineModel, onBack: () -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    val triage by engine.triage.collectAsState()
    val windowRaw by engine.processingWindow.collectAsState()
    val window = ProcessingWindow.from(windowRaw)
    var labels by remember { mutableStateOf(engine.triageLabels()) }
    var labelError by remember { mutableStateOf<String?>(null) }
    // The label open in the editor; `isNew` = adding a custom label.
    var editing by remember { mutableStateOf<TriageLabelDef?>(null) }
    var isNew by remember { mutableStateOf(false) }

    /** Store the whole list; the core validates and returns what it stored. */
    suspend fun save(next: List<TriageLabelDef>): String? =
        engine.saveTriageLabels(next).fold({ labels = it; null }, { it.message ?: "Couldn't save labels" })

    editing?.let { label ->
        TriageLabelEditor(
            label, isNew,
            onBack = { editing = null },
            onSave = { edited ->
                val next = if (isNew) labels + edited else labels.map { if (it.slug == label.slug) edited else it }
                save(next).also { if (it == null) editing = null }
            },
            onDelete = if (label.builtin || isNew) null else ({
                save(labels.filter { it.slug != label.slug }).also { if (it == null) editing = null }
            }),
        )
        return
    }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader("Triage & sync", showBack = true, onBack = onBack)

        SectionLabel("Progress")
        Column(Modifier.insetCard().padding(Space.s4)) {
            LinearProgressIndicator(
                progress = { triage.fraction },
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(3.dp)),
                color = p.accentViolet, trackColor = p.bgInput,
            )
            Spacer(Modifier.height(Space.s2))
            // What the bar means + the date the worker is at (newest-first) — iOS TriageProgressBar.
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                val caption = when {
                    triage.inWindow == 0 -> "Nothing to process yet"
                    !triage.isActive -> "All ${triage.inWindow} conversations sorted"
                    else -> "Sorting ${triage.done} of ${triage.inWindow}"
                }
                Text(caption, style = AppFont.xs, color = p.textTertiary, modifier = Modifier.weight(1f))
                triage.currentDate?.let { com.inbox2.app.model.RelativeTime.parse(it) }?.let { d ->
                    Text(java.text.SimpleDateFormat("d MMM yyyy", java.util.Locale.getDefault()).format(d), style = AppFont.xs, color = p.textMuted)
                }
            }
            Spacer(Modifier.height(Space.s1))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (triage.isActive) "Working…" else "Up to date",
                    style = AppFont.sm,
                    color = if (triage.isActive) p.textSecondary else p.accentSuccess,
                    modifier = Modifier.weight(1f),
                )
                Text("${triage.done} / ${triage.inWindow}", style = AppFont.sm, color = p.textTertiary)
            }
        }

        SectionLabel("How far back to triage")
        Column(Modifier.insetCard()) {
            ProcessingWindow.entries.forEach { w ->
                Row(
                    Modifier.fillMaxWidth()
                        .noRippleClickable {
                            scope.launch { engine.setProcessingWindow(w) }
                        }
                        .padding(horizontal = Space.s4, vertical = Space.s3),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(w.label, style = AppFont.body, color = p.textSecondary, modifier = Modifier.weight(1f))
                    if (w == window) Icon(SfIcon.vector("checkmark"), null, tint = p.accentViolet, modifier = Modifier.size(20.dp))
                }
            }
        }

        Text(
            "Newest mail goes first. A longer range adds older mail in the background.",
            color = p.textTertiary, style = AppFont.xs,
            modifier = Modifier.padding(horizontal = Space.s4, vertical = Space.s3),
        )

        SectionLabel("Labels")
        Column(Modifier.insetCard()) {
            labels.forEach { l ->
                Row(
                    Modifier.fillMaxWidth()
                        .noRippleClickable { isNew = false; editing = l }
                        .padding(horizontal = Space.s4, vertical = Space.s2),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(l.name, style = AppFont.body, color = if (l.enabled) p.textSecondary else p.textTertiary)
                        Text(if (l.builtin) "Built-in" else "Custom · ${l.slug}", style = AppFont.xs2, color = p.textTertiary)
                    }
                    // fyi is the fallback label: always on.
                    Switch(
                        colors = com.inbox2.app.ui.components.inboxSwitchColors(),
                        checked = l.enabled, enabled = l.slug != TriageLabelDef.FALLBACK,
                        onCheckedChange = { on ->
                            scope.launch {
                                labelError = save(labels.map { if (it.slug == l.slug) it.copy(enabled = on) else it })
                            }
                        },
                    )
                }
            }
            Text(
                "+ Add label", color = p.accentViolet, style = AppFont.sm,
                modifier = Modifier.fillMaxWidth()
                    .noRippleClickable { isNew = true; editing = TriageLabelDef(slug = "", name = "") }
                    .padding(horizontal = Space.s4, vertical = Space.s3),
            )
        }
        labelError?.let {
            Text(it, color = p.accentDanger, style = AppFont.xs, modifier = Modifier.padding(horizontal = Space.s4, vertical = Space.s2))
        }
        Text(
            "Jev gives each thread one of the labels you turn on. It reads what each label is for. FYI catches the rest and stays on.",
            color = p.textTertiary, style = AppFont.xs,
            modifier = Modifier.padding(horizontal = Space.s4, vertical = Space.s3),
        )
        Spacer(Modifier.height(Space.s8))
    }
}

/** Edit one label: built-ins change description + not-for; custom labels also set
 *  a name (and a slug when new) and can be deleted. Save returns the core's error. */
@Composable
private fun TriageLabelEditor(
    label: TriageLabelDef,
    isNew: Boolean,
    onBack: () -> Unit,
    onSave: suspend (TriageLabelDef) -> String?,
    onDelete: (suspend () -> String?)?,
) {
    val p = theme
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(label.name) }
    var slug by remember { mutableStateOf(label.slug) }
    var description by remember { mutableStateOf(label.description) }
    var notFor by remember { mutableStateOf(label.notFor) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    // A new label's slug follows its name until edited by hand.
    var slugTouched by remember { mutableStateOf(false) }

    fun run(block: suspend () -> String?) {
        busy = true; error = null
        scope.launch { error = block(); busy = false }
    }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader(if (isNew) "New label" else label.name, showBack = true, onBack = onBack)
        Column(Modifier.padding(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s3)) {
            if (!label.builtin) {
                LabelField("Name", name, singleLine = true) {
                    name = it
                    if (isNew && !slugTouched) slug = it.lowercase().replace(Regex("[^a-z0-9]+"), "_").trim('_').take(40)
                }
            }
            if (isNew) LabelField("Slug", slug, singleLine = true) { slug = it; slugTouched = true }
            LabelField("What it's for", description) { description = it }
            LabelField("Not for (optional)", notFor) { notFor = it }
            error?.let { Text(it, color = p.accentDanger, style = AppFont.xs) }
            val valid = description.isNotBlank() && (label.builtin || name.isNotBlank()) &&
                (!isNew || TriageLabelDef.SLUG.matches(slug))
            PillButton(if (busy) "Saving…" else "Save", busy = busy, enabled = valid) {
                run { onSave(label.copy(slug = slug, name = name.trim(), description = description.trim(), notFor = notFor.trim())) }
            }
            if (onDelete != null) {
                var confirm by remember { mutableStateOf(false) }
                Text(
                    "Delete label", color = p.accentDanger, style = AppFont.sm,
                    modifier = Modifier.noRippleClickable { if (!busy) confirm = true }.padding(vertical = Space.s2),
                )
                if (confirm) androidx.compose.material3.AlertDialog(
                    onDismissRequest = { confirm = false }, containerColor = p.bgElevated,
                    title = { Text("Delete “${label.name}”?", color = p.textPrimary, style = AppFont.md) },
                    text = { Text("Threads already labelled keep it until they're triaged again.", color = p.textSecondary, style = AppFont.sm) },
                    confirmButton = { Text("Delete label", color = p.accentDanger, style = AppFont.md, modifier = Modifier.padding(Space.s2).noRippleClickable { confirm = false; run { onDelete() } }) },
                    dismissButton = { Text("Cancel", color = p.accentViolet, style = AppFont.md, modifier = Modifier.padding(Space.s2).noRippleClickable { confirm = false }) },
                )
            }
        }
    }
}

@Composable
private fun LabelField(label: String, value: String, singleLine: Boolean = false, onChange: (String) -> Unit) {
    val p = theme
    Column {
        Text(label.uppercase(), color = p.textTertiary, style = AppFont.xs3, modifier = Modifier.padding(bottom = Space.s1))
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2 + 2.dp)) {
            BasicTextField(
                value, onChange, singleLine = singleLine, minLines = if (singleLine) 1 else 3,
                textStyle = AppFont.sm.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text.uppercase(),
        style = AppFont.xs3,
        color = theme.textTertiary,
        modifier = Modifier.padding(start = Space.s4, top = Space.s5, bottom = Space.s2),
    )
}
