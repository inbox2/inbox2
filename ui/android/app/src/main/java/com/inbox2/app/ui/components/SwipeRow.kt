package com.inbox2.app.ui.components

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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// Swipeable conversation row (moved out of InboxScreen.kt, 2026-10-18): swipe-right
// toggles read, swipe-left reveals Trash · Archive, a full swipe archives outright.
/** Swipe-left resting anchors: a partial swipe reveals Trash · Archive buttons, a
 *  full swipe archives outright (iOS swipeActions allowsFullSwipe). Swipe-right
 *  still fires read/unread and snaps back. */
internal enum class SwipeAnchor { Read, Closed, Reveal, Archive }

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun SwipeRow(
    convo: Conversation, restoreAction: ConversationAction?, modifier: Modifier = Modifier,
    channelBadge: com.inbox2.app.ui.components.ChannelBadgeInfo? = null,
    onArchive: () -> Unit, onTrash: () -> Unit, onToggleRead: () -> Unit, onOpen: () -> Unit,
    onLongPress: (androidx.compose.ui.geometry.Offset) -> Unit, onAvatarLongPress: (() -> Unit)? = null,
) {
    val p = theme
    val density = androidx.compose.ui.platform.LocalDensity.current
    val scope = rememberCoroutineScope()
    val actionWidth = 76.dp
    val revealPx = with(density) { (actionWidth * 2).toPx() }
    val readPx = with(density) { 96.dp.toPx() }
    var widthPx by remember { mutableStateOf(0f) }

    val state = remember {
        AnchoredDraggableState(
            initialValue = SwipeAnchor.Closed,
            positionalThreshold = { distance -> distance * 0.5f },
            velocityThreshold = { with(density) { 1250.dp.toPx() } },
            snapAnimationSpec = androidx.compose.animation.core.tween(),
            decayAnimationSpec = androidx.compose.animation.core.exponentialDecay(),
            confirmValueChange = { v ->
                when (v) {
                    SwipeAnchor.Read -> { onToggleRead(); false }   // fire + snap back
                    SwipeAnchor.Archive -> { onArchive(); true }    // full swipe-left
                    else -> true
                }
            },
        )
    }
    LaunchedEffect(widthPx) {
        if (widthPx > 0f) state.updateAnchors(DraggableAnchors {
            SwipeAnchor.Read at readPx
            SwipeAnchor.Closed at 0f
            SwipeAnchor.Reveal at -revealPx
            SwipeAnchor.Archive at -widthPx
        })
    }
    fun closeThen(action: () -> Unit) {
        scope.launch { state.animateTo(SwipeAnchor.Closed) }
        action()
    }

    val offset = if (state.offset.isNaN()) 0f else state.offset
    Box(modifier.fillMaxWidth().onSizeChanged { widthPx = it.width.toFloat() }) {
        if (offset < 0f) {
            // Trash · Archive buttons under the row; past the reveal the whole
            // surface reads archive (the full-swipe outcome).
            Row(Modifier.matchParentSize().clip(RoundedCornerShape(Radius.lg))
                .background(p.accentViolet.copy(alpha = 0.10f)),
                horizontalArrangement = Arrangement.End) {
                ActionZone("trash", p.accentDanger, actionWidth) { closeThen(onTrash) }
                ActionZone(restoreAction?.icon ?: "archivebox", p.accentViolet, actionWidth) { closeThen(onArchive) }
            }
        } else if (offset > 0f) {
            val icon = if (convo.unread) "envelope.open" else "envelope.badge"
            Box(
                Modifier.matchParentSize().clip(RoundedCornerShape(Radius.lg))
                    .background(p.accentViolet.copy(alpha = 0.18f)).padding(horizontal = Space.s5),
                contentAlignment = Alignment.CenterStart,
            ) { Icon(SfIcon.vector(icon), null, tint = p.accentViolet, modifier = Modifier.size(22.dp)) }
        }
        Box(
            Modifier.fillMaxWidth()
                .offset { IntOffset(offset.toInt(), 0) }
                .anchoredDraggable(state, Orientation.Horizontal)
                .background(p.bgPanel)   // the row sits in the well (wellRow), not on the page
                // Tap opens (or closes a revealed row); long-press opens the menu at the
                // touch point. detectTapGestures gives the position directly and only on the
                // long-press, so it doesn't recompose mid-gesture like a press observer would.
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = {
                            if (state.currentValue == SwipeAnchor.Reveal)
                                scope.launch { state.animateTo(SwipeAnchor.Closed) }
                            else onOpen()
                        },
                        onLongPress = { at -> onLongPress(at) },
                    )
                }
        ) { ConversationRow(convo, channelBadge = channelBadge, onAvatarClick = onOpen, onAvatarLongPress = onAvatarLongPress) }
    }
}

/** One revealed swipe action: a fixed-width tinted zone with a centered icon. */
@Composable
internal fun ActionZone(icon: String, tint: androidx.compose.ui.graphics.Color, width: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    Box(
        Modifier.fillMaxHeight().width(width).background(tint.copy(alpha = 0.18f))
            .noRippleClickable { onClick() },
        contentAlignment = Alignment.Center,
    ) { Icon(SfIcon.vector(icon), null, tint = tint, modifier = Modifier.size(20.dp)) }
}
