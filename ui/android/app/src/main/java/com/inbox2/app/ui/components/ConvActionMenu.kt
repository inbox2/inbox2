package com.inbox2.app.ui.components

import androidx.compose.foundation.layout.size
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import com.inbox2.app.model.ConvStatusValue
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConversationAction
import com.inbox2.app.model.MailFolder
import com.inbox2.app.model.Quadrant
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.theme
import uniffi.inbox2_core.FfiBridgeConfig

private enum class MenuSection { ROOT, TRIAGE, SNOOZE, SPEAK, PROCESS }

/** One engine the reader can force a thread's summaries through (iOS MessageProcessMenu.ProcessOption). */
data class ProcessOption(val id: String, val name: String, val icon: String, val config: FfiBridgeConfig)

/**
 * The reader-only "Speak with" payload (iOS speakWithMenu + MessageProcessMenu): the three
 * stored summary tiers to read aloud, the full-message reader, and the "Process with" engines
 * that re-run the thread's label + summaries. Absent on inbox-row menus.
 */
class SpeakWith(
    val short: String?,
    val medium: String?,
    val large: String?,
    val onSpeak: (String) -> Unit,
    val onSpeakFull: () -> Unit,
    val processOptions: List<ProcessOption>,
    val onProcess: (ProcessOption) -> Unit,
)

/**
 * Shared conversation-action menu (iOS rowMenu / moreMenu): reply/forward (reader),
 * mark read/unread, a **Triage** submenu (Eisenhower quadrants, offline channels) and a
 * **Snooze** submenu (domain pool) that drill in like iOS, Move to Inbox, archive/trash/
 * spam. Used by the inbox long-press and the reader overflow so both surfaces stay in sync.
 * [offset] positions the menu at the touch point (iOS context menus open under the finger).
 */
@Composable
fun ConvActionMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    convo: Conversation,
    onAction: (ConversationAction) -> Unit,
    onSnooze: ((SnoozeWhen) -> Unit)? = null,
    /** Inbox rows lead with Read aloud (iOS); the reader has its header speaker instead. */
    onReadAloud: (() -> Unit)? = null,
    /** Reply/forward actions (reader only — iOS keeps these in the ••• menu, no bottom bar). */
    onReply: (() -> Unit)? = null,
    onReplyAll: (() -> Unit)? = null,
    onForward: (() -> Unit)? = null,
    /** Reader-only "Speak with" summary tiers + "Process with" engines (iOS). Null on rows. */
    speak: SpeakWith? = null,
    /** The folder the thread is open in (reader only) — hides destructive actions that
     *  are redundant there (Archive in Archive/Trash/Sent, Trash in Trash). Null on the
     *  inbox row menu, where per-status hiding already applies. */
    folder: MailFolder? = null,
    /** Open at the touch point (inbox tap-&-hold). Zero = anchor default (reader •••). */
    offset: DpOffset = DpOffset(0.dp, 0.dp),
) {
    val p = theme
    // Drill-in submenu state; resets to the root each time the menu (re)opens.
    var section by remember(expanded) { mutableStateOf(MenuSection.ROOT) }

    GlassDropdownMenu(expanded = expanded, onDismissRequest = onDismiss, offset = offset) {
        when (section) {
            MenuSection.ROOT -> {
                if (onReply != null || onReplyAll != null || onForward != null) {
                    onReply?.let { MenuRow("Reply", "arrowshape.turn.up.left", p.accentViolet) { it(); onDismiss() } }
                    onReplyAll?.let { MenuRow("Reply all", "arrowshape.turn.up.left.2", p.accentViolet) { it(); onDismiss() } }
                    onForward?.let { MenuRow("Forward", "arrowshape.turn.up.right", p.accentViolet) { it(); onDismiss() } }
                    HorizontalDivider()
                }
                if (onReadAloud != null) {
                    MenuRow("Read aloud", "speaker.wave.2") { onReadAloud(); onDismiss() }
                    HorizontalDivider()
                }
                if (speak != null) {
                    MenuRow("Speak with", "speaker.wave.2", trailing = true) { section = MenuSection.SPEAK }
                    HorizontalDivider()
                }
                if (convo.unread) MenuRow("Mark read", "envelope.open") { onAction(ConversationAction.MarkRead); onDismiss() }
                else MenuRow("Mark unread", "envelope.badge") { onAction(ConversationAction.MarkUnread); onDismiss() }

                ConversationAction.restore(convo.status)?.let { restore ->
                    MenuRow("Move to Inbox", "tray.and.arrow.down", p.accentViolet) { onAction(restore); onDismiss() }
                }

                // Triage / Snooze drill into submenus (iOS nested menus).
                if (!convo.isDomain) {
                    HorizontalDivider()
                    MenuRow("Triage", "flame.fill", trailing = true) { section = MenuSection.TRIAGE }
                } else if (onSnooze != null) {
                    HorizontalDivider()
                    MenuRow("Snooze", "clock", trailing = true) { section = MenuSection.SNOOZE }
                }

                HorizontalDivider()
                if (folder?.hidesArchiveAction != true && convo.status != ConvStatusValue.ARCHIVED)
                    MenuRow("Archive", "archivebox") { onAction(ConversationAction.Archive); onDismiss() }
                // Spam sits above Trash on every channel and keeps the normal tint:
                // it's a filing move — the domain trains Rspamd, offline channels move
                // it to the provider's junk folder. Only Trash reads danger-red.
                if (convo.status != ConvStatusValue.SPAM)
                    MenuRow("Mark as spam", "exclamationmark.octagon") { onAction(ConversationAction.Spam); onDismiss() }
                if (folder?.hidesTrashAction != true && convo.status != ConvStatusValue.TRASH)
                    MenuRow("Trash", "trash", p.accentDanger) { onAction(ConversationAction.Trash); onDismiss() }
            }

            MenuSection.TRIAGE -> {
                MenuBackRow("Triage") { section = MenuSection.ROOT }
                HorizontalDivider()
                Quadrant.entries.forEach { q ->
                    MenuRow(q.label, q.icon) { onAction(ConversationAction.SetQuadrant(q)); onDismiss() }
                }
                MenuRow("Clear triage", "xmark.circle") { onAction(ConversationAction.ClearQuadrant); onDismiss() }
            }

            MenuSection.SNOOZE -> {
                MenuBackRow("Snooze") { section = MenuSection.ROOT }
                HorizontalDivider()
                MenuRow("Later today", "clock") { onSnooze?.invoke(SnoozeWhen.LATER_TODAY); onDismiss() }
                MenuRow("Tomorrow", "clock") { onSnooze?.invoke(SnoozeWhen.TOMORROW); onDismiss() }
                MenuRow("Next week", "clock") { onSnooze?.invoke(SnoozeWhen.NEXT_WEEK); onDismiss() }
            }

            // Read a stored summary tier / the full message aloud — no generation, straight
            // from local data (iOS speakWithMenu). Only the tiers we actually have are shown.
            MenuSection.SPEAK -> {
                MenuBackRow("Speak with") { section = MenuSection.ROOT }
                HorizontalDivider()
                speak?.let { s ->
                    s.short?.takeIf { it.isNotBlank() }?.let { t -> MenuRow("Small", "text.alignleft") { s.onSpeak(t); onDismiss() } }
                    s.medium?.takeIf { it.isNotBlank() }?.let { t -> MenuRow("Medium", "text.justify.left") { s.onSpeak(t); onDismiss() } }
                    s.large?.takeIf { it.isNotBlank() }?.let { t -> MenuRow("Large", "text.justify") { s.onSpeak(t); onDismiss() } }
                    HorizontalDivider()
                    MenuRow("Full message", "doc.plaintext") { s.onSpeakFull(); onDismiss() }
                    // Domain threads are summarized server-side; nothing to force locally.
                    if (!convo.isDomain && s.processOptions.isNotEmpty()) {
                        HorizontalDivider()
                        MenuRow("Process with", "brain", trailing = true) { section = MenuSection.PROCESS }
                    }
                }
            }

            // Re-run this thread's label + summaries through a chosen engine (iOS MessageProcessMenu).
            MenuSection.PROCESS -> {
                MenuBackRow("Process with") { section = MenuSection.SPEAK }
                HorizontalDivider()
                speak?.processOptions?.forEach { opt ->
                    MenuRow(opt.name, opt.icon) { speak.onProcess(opt); onDismiss() }
                }
            }
        }
    }
}

@Composable
private fun MenuRow(
    label: String,
    icon: String,
    tint: androidx.compose.ui.graphics.Color = theme.textPrimary,
    trailing: Boolean = false,
    onClick: () -> Unit,
) {
    DropdownMenuItem(
        text = { Text(label, color = theme.textPrimary, style = AppFont.sm) },
        leadingIcon = { Icon(SfIcon.vector(icon), null, tint = tint, modifier = Modifier.size(18.dp)) },
        trailingIcon = if (trailing) {
            { Icon(SfIcon.vector("chevron.right"), null, tint = theme.textTertiary, modifier = Modifier.size(16.dp)) }
        } else null,
        onClick = onClick,
    )
}

/** Submenu header — a back chevron + bold title that returns to the root menu. */
@Composable
private fun MenuBackRow(label: String, onBack: () -> Unit) {
    DropdownMenuItem(
        text = { Text(label, color = theme.textPrimary, style = AppFont.ui(14, FontWeight.SemiBold)) },
        leadingIcon = { Icon(SfIcon.vector("chevron.left"), null, tint = theme.textSecondary, modifier = Modifier.size(16.dp)) },
        onClick = onBack,
    )
}

/** Snooze horizons (iOS reader/row snooze submenu). */
enum class SnoozeWhen(val label: String) {
    LATER_TODAY("Later today"), TOMORROW("Tomorrow"), NEXT_WEEK("Next week");

    /** iOS SnoozeDate: later today = +3 h; tomorrow / next week = 09:00 local. */
    fun date(now: java.util.Calendar = java.util.Calendar.getInstance()): java.util.Date {
        val c = now.clone() as java.util.Calendar
        when (this) {
            LATER_TODAY -> c.add(java.util.Calendar.HOUR_OF_DAY, 3)
            TOMORROW, NEXT_WEEK -> {
                c.add(java.util.Calendar.DAY_OF_YEAR, if (this == TOMORROW) 1 else 7)
                c.set(java.util.Calendar.HOUR_OF_DAY, 9); c.set(java.util.Calendar.MINUTE, 0)
                c.set(java.util.Calendar.SECOND, 0); c.set(java.util.Calendar.MILLISECOND, 0)
            }
        }
        return c.time
    }
}
