package com.inbox2.app.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.TriageLabelNames
import com.inbox2.app.engine.TriagePriority
import com.inbox2.app.model.ConvStatus
import com.inbox2.app.model.Conversation
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme

/** A conversation list row (iOS ConversationRow): avatar, sender, time, subject,
 *  snippet, message count, status tag, unread dot.
 *
 *  Long-press is split by region: holding the avatar fires [onAvatarLongPress]
 *  (the inbox enters multi-select); holding the text column falls through to the
 *  row's own long-press (the action menu). [onAvatarClick] keeps a plain tap on
 *  the avatar opening the conversation, since its clickable eats the parent's. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ConversationRow(
    convo: Conversation,
    modifier: Modifier = Modifier,
    channelBadge: ChannelBadgeInfo? = null,
    onAvatarClick: (() -> Unit)? = null,
    onAvatarLongPress: (() -> Unit)? = null,
) {
    val p = theme
    Row(
        modifier.padding(vertical = Space.s2),
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(Space.s3),
    ) {
        Box(contentAlignment = Alignment.BottomEnd) {
            AvatarRing(
                initials = convo.initials, size = 48.dp, seed = convo.seed, email = convo.email,
                modifier = if (onAvatarLongPress != null) Modifier.combinedClickable(
                    interactionSource = remember { MutableInteractionSource() }, indication = null,
                    onClick = { onAvatarClick?.invoke() }, onLongClick = onAvatarLongPress,
                ) else Modifier,
            )
            // Channel badge (unified inbox only) sits in the bottom-right corner.
            if (channelBadge != null) ChannelBadge(
                channelBadge,
                modifier = Modifier.offset(x = 2.dp, y = 2.dp),
            )
        }
        Column(Modifier.weight(1f).alpha(if (convo.unread) 1f else 0.82f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    convo.sender,
                    style = AppFont.ui(14, if (convo.unread) FontWeight.Bold else FontWeight.Medium),
                    color = if (convo.unread) p.textSender else p.textPrimary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(Space.s2))
                Text(
                    convo.time, style = AppFont.xs2,
                    color = if (convo.unread) p.accentViolet else p.textTertiary,
                )
            }
            Text(
                convo.subject,
                style = AppFont.ui(14, if (convo.unread) FontWeight.Bold else FontWeight.Normal),
                color = if (convo.unread) p.textPrimary else p.textSecondary,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    convo.preview, style = AppFont.xs, color = p.textTertiary,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(Space.s2))
                if (convo.messageCount > 1) {
                    Text(
                        "${convo.messageCount}", style = AppFont.xs3, color = p.textTertiary,
                        modifier = Modifier
                            .clip(RoundedCornerShape(com.inbox2.app.theme.Radius.full))
                            .background(p.bgElevated).padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                    Spacer(Modifier.width(Space.s2))
                }
                convo.priority?.let { pr ->
                    InboxTag(pr.label, if (pr == TriagePriority.URGENT) p.accentDanger else p.accentAmber)
                    Spacer(Modifier.width(Space.s2))
                }
                // Built-in labels keep their badge (fyi/resolved show none); a custom
                // slug gets a neutral chip with the label's name (docs/Triage.md).
                val triage = convo.triage
                val triageBadge = triage?.rowBadge
                val custom = convo.triageLabel?.takeIf { triage == null }
                if (triage != null && triageBadge != null) {
                    InboxTag(triageBadge, triageColor(triage, p))
                    Spacer(Modifier.width(Space.s2))
                } else if (custom != null) {
                    InboxTag(TriageLabelNames.name(custom, convo.accountKey, convo.isDomain), p.textTertiary)
                    Spacer(Modifier.width(Space.s2))
                } else convo.badge?.let { status ->
                    InboxTag(status.label, statusColor(status, p))
                    Spacer(Modifier.width(Space.s2))
                }
                if (convo.unread) Box(Modifier.size(8.dp).clip(CircleShape).background(p.groove?.led ?: p.accentViolet))
            }
        }
    }
}

private fun statusColor(s: ConvStatus, p: com.inbox2.app.theme.ThemePalette) = when (s) {
    ConvStatus.OPEN -> p.statusOpen
    ConvStatus.PENDING -> p.statusPending
    ConvStatus.URGENT -> p.statusUrgent
    ConvStatus.AI -> p.statusAI
    ConvStatus.ARCHIVED -> p.statusArchived
}

/** Tint for the triage chip, reusing the status palette tokens (mirrors iOS). */
private fun triageColor(t: com.inbox2.app.engine.TriageLabel, p: com.inbox2.app.theme.ThemePalette) = when (t) {
    com.inbox2.app.engine.TriageLabel.NEEDS_ANSWER,
    com.inbox2.app.engine.TriageLabel.ACTION_REQUIRED,
    com.inbox2.app.engine.TriageLabel.PAYMENT_DUE -> p.statusUrgent
    com.inbox2.app.engine.TriageLabel.NEEDS_APPROVAL -> p.statusPending
    com.inbox2.app.engine.TriageLabel.WAITING_REPLY,
    com.inbox2.app.engine.TriageLabel.NEEDS_ANSWER_OTHER,
    com.inbox2.app.engine.TriageLabel.SCHEDULING,
    com.inbox2.app.engine.TriageLabel.TO_REVIEW,
    com.inbox2.app.engine.TriageLabel.READ_LATER -> p.statusOpen
    com.inbox2.app.engine.TriageLabel.FYI,
    com.inbox2.app.engine.TriageLabel.RESOLVED,
    com.inbox2.app.engine.TriageLabel.RECEIPT,
    com.inbox2.app.engine.TriageLabel.NOTIFICATION -> p.statusArchived
}
