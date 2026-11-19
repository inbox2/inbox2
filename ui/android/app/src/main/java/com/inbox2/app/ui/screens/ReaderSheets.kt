package com.inbox2.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.AccountKey
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConversationAction
import com.inbox2.app.model.MailFolder
import com.inbox2.app.model.Message
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ProcessingHairline
import com.inbox2.app.ui.components.*
import uniffi.inbox2_core.FfiBridgeConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Reader sheets/blocks (split out of ReaderScreen.kt, 2026-10-18): the view-source
// sheet and the open-history block.
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
internal fun ViewSourceSheet(msg: Message, onDismiss: () -> Unit) {
    val p = theme
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.bgPanel) {
        Column(Modifier.padding(Space.s4).fillMaxWidth().heightIn(max = 520.dp)
            .verticalScroll(androidx.compose.foundation.rememberScrollState())) {
            Text("Source", color = p.textPrimary, style = AppFont.title2)
            val headers = buildString {
                appendLine("From: ${msg.fromAddress}")
                appendLine("To: ${msg.toAddress}")
                msg.ccAddress?.let { appendLine("Cc: $it") }
                appendLine("Subject: ${msg.subject}")
                appendLine("Date: ${msg.createdAt}")
            }
            Text(headers, color = p.textSecondary, style = AppFont.mono(11), modifier = Modifier.padding(top = Space.s2))
            Text(msg.bodyHTML ?: msg.bodyPlain ?: "(no body)", color = p.textTertiary,
                style = AppFont.mono(11), modifier = Modifier.padding(top = Space.s3, bottom = Space.s8))
        }
    }
}

// Open history (who/when/where) for a sent tracked message (docs/Open-Tracking.md).
@Composable
internal fun OpenHistoryBlock(opens: List<com.inbox2.app.engine.MessageOpen>, p: com.inbox2.app.theme.ThemePalette) {
    Column(
        Modifier.fillMaxWidth().padding(top = Space.s2)
            .clip(RoundedCornerShape(Radius.md)).background(p.bgSurface).padding(Space.s3),
        verticalArrangement = Arrangement.spacedBy(Space.s2),
    ) {
        Text("OPEN HISTORY", color = p.textTertiary, style = AppFont.xs3)
        if (opens.isEmpty()) Text("No opens yet.", color = p.textTertiary, style = AppFont.xs2)
        opens.forEach { o ->
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(o.openedAt, color = p.textPrimary, style = AppFont.xs, modifier = Modifier.weight(1f))
                    if (o.proxied) {
                        Text(o.proxyKind ?: "proxy", color = p.accentAmber, style = AppFont.xs3,
                            modifier = Modifier.clip(RoundedCornerShape(Radius.full))
                                .background(p.accentAmber.copy(alpha = 0.14f)).padding(horizontal = 6.dp, vertical = 2.dp))
                    }
                }
                Text(o.location, color = p.textSecondary, style = AppFont.xs2)
                o.userAgent?.takeIf { it.isNotEmpty() }?.let {
                    Text(it, color = p.textTertiary, style = AppFont.xs3, maxLines = 2)
                }
            }
        }
    }
}
