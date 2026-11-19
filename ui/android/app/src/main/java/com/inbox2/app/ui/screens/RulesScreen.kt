package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.LocalRule
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.EmptyState
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import androidx.compose.material3.Icon
import com.inbox2.app.ui.components.insetCard
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/** Auto-rules (iOS NewRuleSheet + list): list local_rules with inline enable toggle +
 *  a New/Edit sheet building the conditions/action JSON the core writes. run_agent rules
 *  are desktop-only (shown read-only). */
@Composable
fun RulesScreen(engine: EngineModel, onBack: () -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    val dataVersion by engine.dataVersion.collectAsState()
    var rules by remember { mutableStateOf<List<LocalRule>>(emptyList()) }
    var editing by remember { mutableStateOf<LocalRule?>(null) }
    var creating by remember { mutableStateOf(false) }

    // localRules() is a synchronous SQLite read under the store lock; a LaunchedEffect
    // body runs on the main dispatcher, so move it to IO (parity with every other screen).
    LaunchedEffect(dataVersion) {
        rules = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { engine.store.localRules() }
    }

    Column(Modifier.fillMaxSize().background(p.bgBase)) {
        ScreenHeader("Auto rules", showBack = true, onBack = onBack) {
            Icon(SfIcon.vector("plus"), "New rule", tint = p.accentViolet,
                modifier = Modifier.size(24.dp).noRippleClickable { creating = true })
        }
        if (rules.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(bottom = 60.dp), contentAlignment = Alignment.Center) {
                EmptyState("exclamationmark.circle", "No rules yet", "Auto-file, triage, or mark mail as it arrives")
            }
        } else {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(top = Space.s2)) {
                rules.forEach { rule ->
                    Column(Modifier.insetCard().padding(Space.s3)
                        .noRippleClickable(enabled = !rule.needsDesktop) { editing = rule }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(rule.name, color = p.textPrimary, style = AppFont.md, maxLines = 1)
                                Text(rule.conditionSummary, color = p.textTertiary, style = AppFont.xs, maxLines = 2)
                                Text(rule.actionSummary + if (rule.needsDesktop) " · desktop only" else "",
                                    color = p.textSecondary, style = AppFont.xs2)
                            }
                            Switch(colors = com.inbox2.app.ui.components.inboxSwitchColors(), checked = rule.enabled, onCheckedChange = { on ->
                                scope.launch { engine.setRuleEnabled(rule.key, on) }
                            })
                            var confirm by remember(rule.key) { mutableStateOf(false) }
                            Icon(SfIcon.vector("trash"), "Delete rule", tint = p.textTertiary,
                                modifier = Modifier.padding(start = Space.s2).size(18.dp).noRippleClickable { confirm = true })
                            if (confirm) DeleteRuleDialog(rule.name, onCancel = { confirm = false }) {
                                confirm = false
                                scope.launch { engine.deleteRule(rule.key) }
                            }
                        }
                    }
                    Spacer(Modifier.height(Space.s2))
                }
                Spacer(Modifier.height(40.dp))
            }
        }
    }

    if (creating || editing != null) {
        RuleSheet(engine, editing, onDismiss = { creating = false; editing = null })
    }
}

private data class CondRow(var field: String = "from", var op: String = "contains", var value: String = "")

private val FIELDS = listOf("from", "to", "subject", "body", "has_attachment")
private fun isBool(field: String) = field == "has_attachment"
private fun opsFor(field: String) = if (isBool(field)) listOf("is_true", "is_false") else listOf("contains", "equals", "starts_with", "ends_with")
private val ACTIONS = listOf(
    "Archive" to JSONObject().put("type", "perform_action").put("builtin", "archive"),
    "Mark read" to JSONObject().put("type", "perform_action").put("builtin", "mark_read"),
    "Priority" to JSONObject().put("type", "perform_action").put("builtin", "auto_triage").put("quadrant", com.inbox2.app.model.Quadrant.DO_FIRST.raw),
    "Schedule" to JSONObject().put("type", "perform_action").put("builtin", "auto_triage").put("quadrant", com.inbox2.app.model.Quadrant.SCHEDULE.raw),
    "Delegate" to JSONObject().put("type", "perform_action").put("builtin", "auto_triage").put("quadrant", com.inbox2.app.model.Quadrant.DELEGATE.raw),
    "Later" to JSONObject().put("type", "perform_action").put("builtin", "auto_triage").put("quadrant", com.inbox2.app.model.Quadrant.LATER.raw),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RuleSheet(engine: EngineModel, editing: LocalRule?, onDismiss: () -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(editing?.name ?: "") }
    val conds = remember { mutableStateListOf<CondRow>().apply { addAll(parseConds(editing)) } }
    var actionIndex by remember { mutableStateOf(parseActionIndex(editing)) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.bgPanel) {
        Column(Modifier.padding(horizontal = Space.s4).padding(bottom = Space.s8).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Space.s3)) {
            Text(if (editing != null) "Edit rule" else "New rule", color = p.textPrimary, style = AppFont.title2)
            RuleField("Name", name) { name = it }

            Text("WHEN (all match)", color = p.textTertiary, style = AppFont.xs2)
            conds.forEachIndexed { i, c ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    Cycle(c.field, FIELDS) { nf -> conds[i] = c.copy(field = nf, op = opsFor(nf).first()) }
                    Cycle(c.op.replace("_", " "), opsFor(c.field).map { it.replace("_", " ") }) { picked ->
                        conds[i] = c.copy(op = picked.replace(" ", "_"))
                    }
                    if (!isBool(c.field)) {
                        Box(Modifier.weight(1f).clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2)) {
                            if (c.value.isEmpty()) Text("value", color = p.textTertiary, style = AppFont.xs)
                            BasicTextField(c.value, { conds[i] = c.copy(value = it) }, singleLine = true,
                                textStyle = AppFont.xs.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                                modifier = Modifier.fillMaxWidth())
                        }
                    } else Spacer(Modifier.weight(1f))
                    if (conds.size > 1) Icon(SfIcon.vector("xmark"), "Remove", tint = p.textTertiary,
                        modifier = Modifier.size(16.dp).noRippleClickable { conds.removeAt(i) })
                }
            }
            Text("+ Add condition", color = p.accentViolet, style = AppFont.xs,
                modifier = Modifier.noRippleClickable { conds.add(CondRow()) })

            Text("THEN", color = p.textTertiary, style = AppFont.xs2)
            Cycle(ACTIONS[actionIndex].first, ACTIONS.map { it.first }) { picked ->
                actionIndex = ACTIONS.indexOfFirst { it.first == picked }.coerceAtLeast(0)
            }
            error?.let { Text(it, color = p.accentDanger, style = AppFont.xs) }

            // Text conditions need a value (an empty "contains" would match all mail); bool
            // conditions are always complete (iOS canSave).
            val canSave = name.isNotBlank() && conds.isNotEmpty() && conds.all { isBool(it.field) || it.value.isNotBlank() }
            PillButton(if (busy) "Saving…" else "Save", busy = busy, enabled = canSave) {
                busy = true; error = null
                val condJson = JSONArray().apply {
                    conds.forEach { c ->
                        put(JSONObject().put("field", c.field).put("op", c.op)
                            .put("value", if (isBool(c.field)) "" else c.value.trim()))
                    }
                }.toString()
                val actJson = ACTIONS[actionIndex].second.toString()
                scope.launch {
                    val ok = if (editing != null) engine.updateBuiltinRule(editing.key, name, condJson, actJson)
                    else engine.createBuiltinRule(name, condJson, actJson, null, true).first
                    busy = false
                    if (ok) onDismiss() else error = "Couldn't save"
                }
            }

            if (editing != null) {
                var confirm by remember { mutableStateOf(false) }
                Text("Delete rule", color = p.accentDanger, style = AppFont.sm,
                    modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = Space.s2)
                        .noRippleClickable { confirm = true })
                if (confirm) DeleteRuleDialog(editing.name, onCancel = { confirm = false }) {
                    confirm = false
                    scope.launch { engine.deleteRule(editing.key); onDismiss() }
                }
            }
        }
    }
}

@Composable
private fun Cycle(current: String, options: List<String>, onPick: (String) -> Unit) {
    val p = theme
    Box(Modifier.clip(RoundedCornerShape(Radius.md)).background(p.bgElevated)
        .noRippleClickable {
            val i = options.indexOf(current).let { if (it < 0) options.indexOfFirst { o -> o.startsWith(current) } else it }
            onPick(options[((i.coerceAtLeast(0)) + 1) % options.size])
        }.padding(horizontal = Space.s2, vertical = Space.s1 + 2.dp)) {
        Text(current, color = p.textPrimary, style = AppFont.xs)
    }
}

@Composable
private fun RuleField(label: String, value: String, onChange: (String) -> Unit) {
    val p = theme
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(64.dp))
        Box(Modifier.weight(1f).clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2 + 2.dp)) {
            BasicTextField(value, onChange, singleLine = true,
                textStyle = AppFont.sm.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                modifier = Modifier.fillMaxWidth())
        }
    }
}

private fun parseConds(rule: LocalRule?): List<CondRow> {
    if (rule == null) return listOf(CondRow())
    return runCatching {
        val arr = JSONArray(rule.conditionsJSON)
        (0 until arr.length()).map { i ->
            val c = arr.getJSONObject(i)
            val f = c.optString("field", "from")
            CondRow(f, c.optString("op", opsFor(f).first()), c.opt("value")?.toString() ?: "")
        }.ifEmpty { listOf(CondRow()) }
    }.getOrDefault(listOf(CondRow()))
}

private fun parseActionIndex(rule: LocalRule?): Int {
    if (rule == null) return 0
    return runCatching {
        val o = JSONObject(rule.actionJSON)
        val quad = o.optString("quadrant")
        if (quad.isNotEmpty()) ACTIONS.indexOfFirst { it.second.optString("quadrant") == quad }
        else ACTIONS.indexOfFirst { it.second.optString("builtin") == o.optString("builtin") }
    }.getOrDefault(0).coerceAtLeast(0)
}

/** "Delete this rule?" (iOS confirmationDialog) — the rule stops running on this device. */
@Composable
private fun DeleteRuleDialog(name: String, onCancel: () -> Unit, onDelete: () -> Unit) {
    val p = theme
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onCancel, containerColor = p.bgElevated,
        title = { Text("Delete this rule?", color = p.textPrimary, style = AppFont.md) },
        text = { Text("${name.ifBlank { "This rule" }} will stop running on this device.", color = p.textSecondary, style = AppFont.sm) },
        confirmButton = { Text("Delete rule", color = p.accentDanger, style = AppFont.md, modifier = Modifier.padding(Space.s2).noRippleClickable(onClick = onDelete)) },
        dismissButton = { Text("Cancel", color = p.accentViolet, style = AppFont.md, modifier = Modifier.padding(Space.s2).noRippleClickable(onClick = onCancel)) },
    )
}
