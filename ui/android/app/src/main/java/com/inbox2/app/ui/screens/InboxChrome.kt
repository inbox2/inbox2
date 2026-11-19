package com.inbox2.app.ui.screens

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.draw.alpha
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.AnchoredDraggableState
import androidx.compose.foundation.gestures.DraggableAnchors
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.anchoredDraggable
import androidx.compose.foundation.gestures.animateTo
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.border
import com.inbox2.app.ui.components.pageGround
import com.inbox2.app.ui.components.groovePanel
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.AccountStatusValue
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.*
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.ChannelColor
import com.inbox2.app.theme.colorHex
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ProcessingHairline
import com.inbox2.app.ui.components.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Inbox chrome (split out of InboxScreen.kt, 2026-10-18; names kept so logcat/greps
// stay valid): the multi-select bulk bar, the glow undo toast and the Outbox folder view.
/** Bulk action bar (replaces the nav, mirroring it): Read/Archive/Triage/Trash, or
 *  Move to Inbox in restore folders. [onAction] runs the action over the selection. */
@Composable
internal fun BulkActionBar(modifier: Modifier, restoreAction: ConversationAction?, onAction: (ConversationAction) -> Unit) {
    val p = theme
        Row(
            modifier.padding(bottom = Space.s4)
                .glowCapsule().padding(horizontal = Space.s2, vertical = Space.s1 + 2.dp),
            horizontalArrangement = Arrangement.spacedBy(Space.s1),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Restore folders lead with Move to Inbox but keep the rest (iOS parity).
            if (restoreAction != null) BulkButton("tray.and.arrow.down") { onAction(restoreAction) }
            BulkButton("envelope.open") { onAction(ConversationAction.MarkRead) }
            BulkButton("archivebox") { onAction(ConversationAction.Archive) }
            // Triage opens a quadrant submenu (any quadrant + clear).
            var triageMenu by remember { mutableStateOf(false) }
            Box {
                BulkButton("exclamationmark.circle") { triageMenu = true }
                androidx.compose.material3.DropdownMenu(triageMenu, onDismissRequest = { triageMenu = false }) {
                    Quadrant.entries.forEach { q ->
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text("Triage: ${q.label}", color = p.textPrimary, style = AppFont.sm) },
                            leadingIcon = { Icon(SfIcon.vector(q.icon), null, tint = p.textSecondary, modifier = Modifier.size(18.dp)) },
                            onClick = { onAction(ConversationAction.SetQuadrant(q)); triageMenu = false },
                        )
                    }
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text("Clear triage", color = p.textPrimary, style = AppFont.sm) },
                        leadingIcon = { Icon(SfIcon.vector("xmark.circle"), null, tint = p.textSecondary, modifier = Modifier.size(18.dp)) },
                        onClick = { onAction(ConversationAction.ClearQuadrant); triageMenu = false },
                    )
                }
            }
            BulkButton("trash") { onAction(ConversationAction.Trash) }
        }
}

@Composable
internal fun BulkButton(icon: String, onClick: () -> Unit) =
    // Idle glyphs sit on the floating nav's gray inactive treatment (textSecondary @ 0.45),
    // reserving the accent for the pressed/active state — matches iOS bulkIcon idleIconColor.
    AeroIconButton(icon, onClick, boxSize = 48.dp, iconSize = 22.dp, tint = theme.textSecondary.copy(alpha = 0.45f))

@Composable
internal fun UndoToast(undo: UndoState, channel: com.inbox2.app.ui.components.ChannelBadgeInfo? = null, onUndo: () -> Unit) {
    val p = theme
    Row(
        Modifier.glowCapsule(colors = toastColors(undo.action)).padding(horizontal = Space.s3, vertical = Space.s2),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2),
    ) {
        // Show the channel avatar when every undone row shares one account; a mixed
        // bulk undo keeps the neutral action glyph rather than misrepresenting one.
        if (channel != null) {
            com.inbox2.app.ui.components.ChannelBadge(channel, size = 28.dp)
        } else {
            Box(Modifier.size(28.dp).clip(CircleShape).background(p.bgElevated), contentAlignment = Alignment.Center) {
                Icon(SfIcon.vector(undo.action.icon), null, tint = p.textPrimary, modifier = Modifier.size(15.dp))
            }
        }
        // One row → show its subject; a bulk action → show the count instead.
        val subtitle = if (undo.count > 1) "${undo.count} conversations"
            else undo.primary?.subject?.ifBlank { "(no subject)" } ?: "(no subject)"
        Column(Modifier.weight(1f)) {
            Text(undo.action.title, color = p.textPrimary, style = AppFont.sm, maxLines = 1)
            Text(subtitle, color = p.textSecondary, style = AppFont.xs,
                maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        }
        undo.action.reverse?.let {
            Text("Undo", color = p.accentViolet, style = AppFont.md,
                modifier = Modifier.noRippleClickable { onUndo() })
        }
    }
}

/** Per-action accent for the toast's gradient border/glow — mirrors the web variants:
 *  destructive (trash) reads coral, triage (archive/spam/quadrant) reads amber, the
 *  rest stay the neutral inbox violet. */
internal fun toastColors(action: ConversationAction): List<Color> = when (action) {
    ConversationAction.Trash -> ChannelColor.coralGradient                         // coral — destructive
    ConversationAction.Archive, ConversationAction.Spam, ConversationAction.ClearQuadrant, is ConversationAction.SetQuadrant ->
        ChannelColor.amberGradient                                                 // amber — triage
    else -> InboxAccent                                                            // violet — neutral
}

/** Outbox view (iOS Outbox folder): queued/failed sends with retry + cancel. */
@Composable
internal fun OutboxView(engine: EngineModel) {
    val p = theme
    val scope = rememberCoroutineScope()
    val dataVersion by engine.dataVersion.collectAsState()
    var items by remember { mutableStateOf<List<OutboxItem>>(emptyList()) }
    LaunchedEffect(dataVersion) { items = withContext(Dispatchers.IO) { engine.store.outboxMessages() } }

    Column(Modifier.fillMaxSize().background(p.bgBase)) {
        ScreenHeader("Outbox")
        if (items.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(bottom = 80.dp), contentAlignment = Alignment.Center) {
                EmptyState("tray.and.arrow.up", "Outbox empty", "Mail that hasn't sent yet shows up here")
            }
        } else {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                items(items, key = { it.id }) { item ->
                    Column(Modifier.insetCard().padding(Space.s3)) {
                        Text(item.subject, color = p.textPrimary, style = AppFont.md, maxLines = 1)
                        Text("To ${item.recipient}", color = p.textTertiary, style = AppFont.xs)
                        Row(Modifier.padding(top = Space.s1), verticalAlignment = Alignment.CenterVertically) {
                            Text(item.statusLine, color = if (item.isFailed) p.accentDanger else p.textTertiary, style = AppFont.xs2)
                            Spacer(Modifier.weight(1f))
                            if (item.isFailed) {
                                Text("Send now", color = p.accentViolet, style = AppFont.xs,
                                    modifier = Modifier.noRippleClickable {
                                        scope.launch { engine.retryOutbox(item.accountKey, item.key) } })
                                Spacer(Modifier.width(Space.s3))
                            }
                            Text("Cancel", color = p.accentDanger, style = AppFont.xs,
                                modifier = Modifier.noRippleClickable {
                                    scope.launch { engine.deleteOutbox(item.accountKey, item.key) } })
                        }
                    }
                }
                item { Spacer(Modifier.height(90.dp)) }
            }
        }
    }
}
