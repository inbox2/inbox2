package com.inbox2.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.engine.LoreSentRef
import com.inbox2.app.engine.McpConnection
import com.inbox2.app.engine.McpDraft
import com.inbox2.app.engine.McpField
import com.inbox2.app.engine.McpJson
import com.inbox2.app.engine.McpPreset
import com.inbox2.app.engine.mcpSignIn
import com.inbox2.app.model.Conversation
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.SfIcon
import kotlinx.coroutines.launch
import org.json.JSONObject

/** Send a Lore item to another app (web `SendToDialog`, docs/MCP-Client.md). Draft-only: the
 *  fields are prefilled and editable and nothing reaches the other app until Create. The
 *  server's text shows as plain text and never opens anything. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SendToSheet(convo: Conversation, engine: EngineModel, onDismiss: () -> Unit, onSent: (LoreSentRef) -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var connections by remember { mutableStateOf<List<McpConnection>?>(null) }
    var presets by remember { mutableStateOf<List<McpPreset>>(emptyList()) }
    var selected by remember { mutableStateOf<McpConnection?>(null) }
    var drafts by remember { mutableStateOf<List<McpDraft>?>(null) }
    var draftIndex by remember { mutableStateOf(0) }
    var values by remember { mutableStateOf<Map<String, String>>(emptyMap()) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    var connecting by remember { mutableStateOf<McpPreset?>(null) }
    var showConnect by remember { mutableStateOf(false) }

    fun message(t: Throwable): String {
        val raw = t.message ?: "That did not work. Try again."
        return if (raw.contains("needs_auth")) "Sign in again to continue." else raw.removePrefix("Engine(message=").removeSuffix(")")
    }

    fun openDraft(i: Int, list: List<McpDraft>) {
        draftIndex = i
        values = list.getOrNull(i)?.values ?: emptyMap()
    }

    suspend fun choose(c: McpConnection) {
        selected = c
        drafts = null
        error = null
        if (c.needsAuth) return
        runCatching { McpJson.drafts(engine.mcp { it.mcpDraftsJson(c.id, McpJson.itemJson(convo)) }) }
            .onSuccess { drafts = it; openDraft(0, it) }
            .onFailure { drafts = emptyList(); error = message(it) }
    }

    suspend fun reload() {
        val rows = McpJson.connections(engine.mcp { it.mcpConnectionsJson() })
        connections = rows
        if (selected == null || rows.none { it.id == selected?.id }) (rows.firstOrNull { !it.needsAuth } ?: rows.firstOrNull())?.let { choose(it) }
    }

    LaunchedEffect(Unit) {
        runCatching {
            presets = McpJson.presets(engine.mcp { it.mcpPresetsJson() })
            reload()
        }.onFailure { connections = emptyList(); error = message(it) }
    }

    fun connect(preset: McpPreset, token: String? = null, clientId: String? = null, clientSecret: String? = null) {
        busy = true
        error = null
        scope.launch {
            runCatching {
                mcpSignIn(context,
                    begin = { redirect -> engine.mcp { it.mcpBeginConnect(preset.name, preset.url, token, clientId, clientSecret, redirect) } },
                    finish = { state, code -> engine.mcp { it.mcpFinishConnect(state, code) } })
                selected = null
                reload()
                showConnect = false
            }.onFailure { error = message(it) }
            busy = false
        }
    }

    fun reauth(c: McpConnection) {
        busy = true
        error = null
        scope.launch {
            runCatching {
                mcpSignIn(context,
                    begin = { redirect -> engine.mcp { it.mcpBeginReauth(c.id, null, redirect) } },
                    finish = { state, code -> engine.mcp { it.mcpFinishConnect(state, code) } })
                reload()
                connections?.firstOrNull { it.id == c.id }?.let { choose(it) }
            }.onFailure { error = message(it) }
            busy = false
        }
    }

    // The person pressed Create: the one place a tool runs.
    fun create() {
        val conn = selected ?: return
        val draft = drafts?.getOrNull(draftIndex) ?: return
        busy = true
        error = null
        scope.launch {
            runCatching {
                val valuesJson = JSONObject(values as Map<*, *>).toString()
                val out = JSONObject(engine.mcp { it.mcpCreate(conn.id, draft.name, valuesJson) })
                val summary = out.optString("summary")
                if (out.optBoolean("is_error")) { error = summary.ifEmpty { "${draft.name} reported an error." }; return@launch }
                result = summary.ifEmpty { "Created." }
                val row = engine.mcp { it.loreSentAdd(LoreSentRef.key(convo), conn.name, summary) }
                onSent(McpJson.sent(JSONObject(row)))
            }.onFailure {
                error = message(it)
                if (message(it).startsWith("Sign in again")) reload()
            }
            busy = false
        }
    }

    val draft = drafts?.getOrNull(draftIndex)
    val missing = draft == null || draft.fields.any { it.required && it.kind != "boolean" && (values[it.key] ?: "").isBlank() }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.bgPanel) {
        Column(Modifier.fillMaxWidth().padding(horizontal = Space.s4).padding(bottom = Space.s6)
            .heightIn(max = 620.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(Space.s3)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Send to…", color = p.textPrimary, style = AppFont.title2, modifier = Modifier.weight(1f))
                if (result == null) {
                    val can = !missing && !busy && selected != null
                    Text("Create", color = if (can) p.accentViolet else p.textTertiary,
                        style = AppFont.base.copy(fontWeight = FontWeight.SemiBold),
                        modifier = Modifier.clickable(enabled = can, onClickLabel = "Create in the other app") { create() }.padding(Space.s2))
                }
            }
            Text(convo.subject, color = p.textSecondary, style = AppFont.sm)
            result?.let {
                Text("Sent", color = p.textTertiary, style = AppFont.xs)
                Text(it, color = p.textPrimary, style = AppFont.sm)
            }
            if (result == null) {
                val rows = connections
                if (rows == null) Text("Loading…", color = p.textTertiary, style = AppFont.sm)
                rows?.forEach { c ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable(onClickLabel = "Send to ${c.name}") { scope.launch { choose(c) } },
                        verticalAlignment = Alignment.CenterVertically) {
                        Text(c.name, color = p.textPrimary, style = AppFont.base, modifier = Modifier.weight(1f))
                        if (c.id == selected?.id) Icon(SfIcon.vector("checkmark"), "Selected", tint = p.accentViolet, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.size(Space.s3))
                        Text("Remove", color = p.textTertiary, style = AppFont.xs,
                            modifier = Modifier.clickable(onClickLabel = "Remove ${c.name}") {
                                scope.launch { runCatching { engine.mcp { it.mcpRemoveConnection(c.id) }; selected = null; drafts = null; reload() }.onFailure { e -> error = message(e) } }
                            }.padding(Space.s2))
                    }
                }
                if (rows != null && rows.isNotEmpty()) {
                    Text("Connect another app", color = p.accentViolet, style = AppFont.sm,
                        modifier = Modifier.clickable { showConnect = !showConnect }.padding(vertical = Space.s2))
                }
                if (rows?.isEmpty() == true || showConnect) {
                    Text("Connect an app", color = p.textTertiary, style = AppFont.xs)
                    presets.forEach { preset ->
                        Text(preset.name, color = p.textPrimary, style = AppFont.base,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 44.dp)
                                .clickable(enabled = !busy, onClickLabel = "Connect ${preset.name}") {
                                    if (preset.auth == "oauth") connect(preset) else connecting = preset
                                }.padding(vertical = Space.s2))
                    }
                }
                connecting?.let { preset -> ConnectFields(preset) { token, id, secret -> connecting = null; connect(preset, token, id, secret) } }
                selected?.takeIf { it.needsAuth }?.let { c ->
                    Text("Sign in again to ${c.name}", color = p.accentViolet, style = AppFont.sm,
                        modifier = Modifier.clickable(enabled = !busy) { reauth(c) }.padding(vertical = Space.s2))
                }
                val list = drafts
                if (list != null && list.size > 1) {
                    var open by remember { mutableStateOf(false) }
                    Text("Action: ${draft?.name.orEmpty()}", color = p.textPrimary, style = AppFont.sm,
                        modifier = Modifier.clickable(onClickLabel = "Change the action") { open = true }.padding(vertical = Space.s2))
                    DropdownMenu(open, onDismissRequest = { open = false }) {
                        list.forEachIndexed { i, d -> DropdownMenuItem(text = { Text(d.name) }, onClick = { open = false; openDraft(i, list) }) }
                    }
                }
                draft?.fields?.forEach { f ->
                    FieldRow(f, values[f.key] ?: "") { v -> values = values + (f.key to v) }
                }
                if (drafts?.isEmpty() == true) Text("This app has no actions.", color = p.textSecondary, style = AppFont.sm)
            }
            error?.let { Text(it, color = p.accentDanger, style = AppFont.sm) }
        }
    }
}

@Composable
private fun FieldRow(f: McpField, value: String, onChange: (String) -> Unit) {
    val p = theme
    val label = if (f.required) "${f.label} *" else f.label
    when (f.kind) {
        "boolean" -> Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = p.textPrimary, style = AppFont.sm, modifier = Modifier.weight(1f))
            Switch(checked = value == "true", onCheckedChange = { onChange(if (it) "true" else "") })
        }
        "enum" -> {
            var open by remember { mutableStateOf(false) }
            Column {
                Text("$label: ${value.ifEmpty { "—" }}", color = p.textPrimary, style = AppFont.sm,
                    modifier = Modifier.clickable(onClickLabel = "Choose $label") { open = true }.padding(vertical = Space.s2))
                DropdownMenu(open, onDismissRequest = { open = false }) {
                    (listOf("") + f.options).forEach { o ->
                        DropdownMenuItem(text = { Text(o.ifEmpty { "—" }) }, onClick = { open = false; onChange(o) })
                    }
                }
            }
        }
        else -> Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            OutlinedTextField(value = value, onValueChange = onChange, label = { Text(label) }, modifier = Modifier.fillMaxWidth(),
                singleLine = f.kind != "json" && !f.key.contains("desc", ignoreCase = true) && !f.key.contains("body", ignoreCase = true),
                colors = fieldColors())
            if (f.description.isNotEmpty()) Text(f.description, color = p.textTertiary, style = AppFont.xs2)
        }
    }
}

@Composable
private fun fieldColors() = theme.let { p ->
    OutlinedTextFieldDefaults.colors(
        focusedTextColor = p.textPrimary, unfocusedTextColor = p.textPrimary,
        focusedBorderColor = p.accentViolet, unfocusedBorderColor = p.borderSubtle,
        focusedLabelColor = p.accentViolet, unfocusedLabelColor = p.textSecondary,
    )
}

@Composable
private fun ConnectFields(preset: McpPreset, onConnect: (String?, String?, String?) -> Unit) {
    val p = theme
    var token by remember { mutableStateOf("") }
    var clientId by remember { mutableStateOf("") }
    var secret by remember { mutableStateOf("") }
    val tokenAuth = preset.auth == "token"
    Column(verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        if (tokenAuth) {
            OutlinedTextField(token, { token = it }, label = { Text("Access token") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(), colors = fieldColors())
        } else {
            OutlinedTextField(clientId, { clientId = it }, label = { Text("Client ID") }, singleLine = true, modifier = Modifier.fillMaxWidth(), colors = fieldColors())
            OutlinedTextField(secret, { secret = it }, label = { Text("Client secret (optional)") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(), colors = fieldColors())
        }
        val can = if (tokenAuth) token.isNotBlank() else clientId.isNotBlank()
        Text("Connect ${preset.name}", color = if (can) p.accentViolet else p.textTertiary, style = AppFont.sm,
            modifier = Modifier.clickable(enabled = can) { onConnect(token.ifBlank { null }, clientId.ifBlank { null }, secret.ifBlank { null }) }.padding(vertical = Space.s2))
    }
}
