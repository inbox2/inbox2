package com.inbox2.app.ui.screens

import com.inbox2.app.ui.components.PillTextButton
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.inbox2.app.model.Conversation
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.*
import kotlinx.coroutines.launch

/**
 * Domain (mx team-pool) collaboration bar: tags (chips + add), assignees (+ picker) and
 * internal notes (+ add). Self-contained — owns its own tag/member palette fetch — so the
 * reader (ReaderScreen) just drops it in for domain threads. Lives in its own file (iOS
 * DomainCollabSection parity).
 */
@Composable
internal fun DomainCollab(cloud: com.inbox2.app.cloud.CloudSession, convo: Conversation, thread: com.inbox2.app.cloud.DomainThread) {
    val p = theme
    val scope = rememberCoroutineScope()
    var allTags by remember { mutableStateOf<List<com.inbox2.app.cloud.CloudTag>>(emptyList()) }
    var members by remember { mutableStateOf<List<com.inbox2.app.cloud.CloudMember>>(emptyList()) }
    var tagMenu by remember { mutableStateOf(false) }
    var assigneeMenu by remember { mutableStateOf(false) }
    var noteText by remember { mutableStateOf("") }
    var newLabel by remember { mutableStateOf<String?>(null) } // non-null while the name dialog is open
    LaunchedEffect(convo.accountKey) { allTags = cloud.tags(convo.accountKey); members = cloud.members(convo.accountKey) }

    Column(Modifier.insetCard().padding(Space.s3), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        // Tags
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(SfIcon.vector("tag"), null, tint = p.textTertiary, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(Space.s2))
            thread.tags.forEach { t ->
                val c = t.color?.let { runCatching { com.inbox2.app.theme.colorHex(it.removePrefix("#")) }.getOrNull() } ?: p.accentViolet
                if (t.isPrivate) Icon(SfIcon.vector("lock.fill"), "Only you", tint = p.textTertiary, modifier = Modifier.size(10.dp).padding(end = 2.dp))
                InboxTag(t.name, c, Modifier.padding(end = 4.dp))
            }
            Box {
                Text("+", color = p.accentViolet, style = AppFont.md,
                    modifier = Modifier.noRippleClickable { tagMenu = true })
                androidx.compose.material3.DropdownMenu(tagMenu, onDismissRequest = { tagMenu = false }) {
                    if (allTags.isEmpty()) androidx.compose.material3.DropdownMenuItem(text = { Text("No tags in this domain", color = p.textTertiary, style = AppFont.sm) }, onClick = { tagMenu = false })
                    allTags.forEach { t ->
                        val on = thread.tags.any { it.id == t.id }
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(if (t.isPrivate) "${t.name} (only you)" else t.name, color = p.textPrimary, style = AppFont.sm) },
                            leadingIcon = { Icon(SfIcon.vector(if (on) "checkmark.circle.fill" else if (t.isPrivate) "lock.fill" else "circle"), null, tint = if (on) p.accentViolet else p.textMuted, modifier = Modifier.size(16.dp)) },
                            onClick = {
                                tagMenu = false
                                // Toggle (iOS toggleTag): on → off, off → on.
                                val ids = thread.tags.map { it.id }
                                val next = if (on) ids - t.id else (ids + t.id).distinct()
                                scope.launch { cloud.setTags(convo.accountKey, convo.id, next) }
                            })
                    }
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("New label just for you…", color = p.accentViolet, style = AppFont.sm) },
                        leadingIcon = { Icon(SfIcon.vector("plus"), null, tint = p.accentViolet, modifier = Modifier.size(16.dp)) },
                        onClick = { tagMenu = false; newLabel = "" })
                }
            }
        }
        newLabel?.let { draft ->
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { newLabel = null },
                title = { Text("New label") },
                text = {
                    Column {
                        Text("Only you see this label.", style = AppFont.sm)
                        androidx.compose.material3.OutlinedTextField(draft, { newLabel = it }, singleLine = true,
                            modifier = Modifier.padding(top = Space.s2))
                    }
                },
                confirmButton = {
                    PillButton("Add", compact = true, enabled = draft.isNotBlank()) {
                        newLabel = null
                        scope.launch {
                            val tag = cloud.createPrivateLabel(convo.accountKey, draft.trim()) ?: return@launch
                            allTags = allTags + tag
                            cloud.setTags(convo.accountKey, convo.id, (thread.tags.map { it.id } + tag.id).distinct())
                        }
                    }
                },
                dismissButton = { PillTextButton("Cancel") { newLabel = null } },
            )
        }
        // Assignees
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(SfIcon.vector("person.2"), null, tint = p.textTertiary, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(Space.s2))
            Text(thread.assignees.joinToString(", ") { it.user?.label ?: "?" }.ifEmpty { "Unassigned" },
                color = p.textSecondary, style = AppFont.xs, modifier = Modifier.weight(1f))
            Box {
                Text("Assign", color = p.accentViolet, style = AppFont.xs,
                    modifier = Modifier.noRippleClickable { assigneeMenu = true })
                androidx.compose.material3.DropdownMenu(assigneeMenu, onDismissRequest = { assigneeMenu = false }) {
                    members.forEach { m ->
                        val on = thread.assignees.any { it.id == m.id }
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(m.user?.label ?: "?", color = p.textPrimary, style = AppFont.sm) },
                            leadingIcon = { Icon(SfIcon.vector(if (on) "checkmark.circle.fill" else "circle"), null, tint = if (on) p.accentViolet else p.textMuted, modifier = Modifier.size(16.dp)) },
                            onClick = {
                                assigneeMenu = false
                                // Toggle membership (iOS toggleAssignee): several people, or nobody.
                                val ids = thread.assignees.map { it.id }.toMutableSet().apply { if (on) remove(m.id) else add(m.id) }
                                scope.launch { cloud.setAssignees(convo.accountKey, convo.id, ids.toList()) }
                            })
                    }
                }
            }
        }
        // Notes
        thread.notes.forEach { n ->
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(p.accentAmber.copy(alpha = 0.08f)).padding(Space.s2 + 2.dp)) {
                Text(n.body, color = p.textPrimary, style = AppFont.sm)
                n.author?.user?.label?.let { Text(it, color = p.textTertiary, style = AppFont.xs3) }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f).clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2)) {
                if (noteText.isEmpty()) Text("Add a note…", color = p.textTertiary, style = AppFont.xs)
                androidx.compose.foundation.text.BasicTextField(noteText, { noteText = it }, singleLine = true,
                    textStyle = AppFont.xs.copy(color = p.textPrimary),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(p.accentViolet), modifier = Modifier.fillMaxWidth())
            }
            if (noteText.isNotBlank()) Text("Post", color = p.accentViolet, style = AppFont.xs,
                modifier = Modifier.padding(start = Space.s2).noRippleClickable {
                    val t = noteText; noteText = ""
                    scope.launch { cloud.addNote(convo.accountKey, convo.id, t) }
                })
        }
    }
}
