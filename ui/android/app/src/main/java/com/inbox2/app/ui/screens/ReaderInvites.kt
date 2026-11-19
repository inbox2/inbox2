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

// Meeting banners of the reader (split out of ReaderScreen.kt, 2026-10-18): the
// Outlook-style invite banner, the meeting-request banner, the nearby-events lookup
// and the invite/plain-text formatting helpers.
/** Outlook-style meeting-invite banner (docs/Meeting-Invites.md): the event summary/
 *  when/location over Accept · Tentative · Decline pills. The chosen response
 *  highlights; after answering, a "You responded" line confirms it. Same behaviour as
 *  the web MeetingInvite. */
@Composable
internal fun MeetingInviteBanner(
    invite: com.inbox2.app.model.ClientInvite, status: String?, busy: Boolean,
    changing: Boolean, onChange: () -> Unit, onRespond: (String) -> Unit,
    addedEventKey: String? = null, addError: String? = null, onAdd: () -> Unit = {},
    nearby: List<com.inbox2.app.model.CalendarEvent> = emptyList(),
    onOpenEvent: (String) -> Unit = {},
) {
    val p = theme
    val responses = listOf("accepted" to "Accept", "tentative" to "Tentative", "declined" to "Decline")
    val start = invite.startDate
    val end = invite.endDate ?: start
    // An event starting within 15 min of a detected meeting is taken to BE it. Time
    // only: the detected title is the model's wording, rarely the one it was saved as.
    val sameTime = if (invite.detected && start != null)
        nearby.firstOrNull { e -> e.start?.let { kotlin.math.abs(it.time - start.time) <= 15 * 60_000 } == true } else null
    Column(
        Modifier.fillMaxWidth().padding(top = Space.s2)
            .clip(RoundedCornerShape(Radius.md)).background(p.bgElevated).padding(Space.s3),
        verticalArrangement = Arrangement.spacedBy(Space.s3),
    ) {
        if (invite.detected) {
            // Not an emailed invite: triage found it in the body.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s1)) {
                Icon(SfIcon.vector("sparkles"), null, tint = p.textSecondary, modifier = Modifier.size(12.dp))
                Text("Found in this email", color = p.textSecondary, style = AppFont.xs2)
            }
        }
        // Tapping the event info opens the calendar straight to this event's detail
        // (only when it maps to a synced calendar event) — iOS meetingInviteBar.
        val linkedKey = invite.matchedEventKey?.takeIf { it.isNotEmpty() }
        Row(
            Modifier.let { m -> if (linkedKey != null) m.noRippleClickable { onOpenEvent(linkedKey) } else m },
            horizontalArrangement = Arrangement.spacedBy(Space.s2),
        ) {
            Icon(SfIcon.vector("calendar"), null, tint = p.accentWarmBright,
                modifier = Modifier.padding(top = 1.dp).size(18.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(invite.summary?.ifBlank { null } ?: "Meeting invitation",
                    color = p.textPrimary, style = AppFont.ui(14, FontWeight.SemiBold), maxLines = 2)
                formatInviteWhen(invite)?.let { Text(it, color = p.textSecondary, style = AppFont.xs) }
                invite.location?.takeIf { it.isNotBlank() }?.let {
                    Text(it, color = p.textSecondary, style = AppFont.xs, maxLines = 1)
                }
            }
            if (linkedKey != null) Icon(SfIcon.vector("chevron.right"), null, tint = p.textTertiary,
                modifier = Modifier.padding(top = 3.dp).size(12.dp))
        }
        if (invite.isAddable && addedEventKey == null && sameTime != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                Icon(SfIcon.vector("checkmark.circle.fill"), null, tint = p.accentSuccess, modifier = Modifier.size(15.dp))
                Text("Already on your calendar: ${sameTime.title}", color = p.textPrimary, style = AppFont.sm, maxLines = 2)
            }
        } else if (invite.isAddable) {
            // Not an invitation to answer — an event to file. One button, then a
            // confirmation once it's on the calendar.
            if (addedEventKey != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    Icon(SfIcon.vector("checkmark.circle.fill"), null, tint = p.accentSuccess, modifier = Modifier.size(15.dp))
                    Text("Added to calendar", color = p.textPrimary, style = AppFont.sm)
                    Spacer(Modifier.weight(1f))
                    // An empty key = filed on the server (MX) but not synced locally yet.
                    if (addedEventKey.isNotEmpty()) Text("View", color = p.accentViolet,
                        style = AppFont.ui(13, FontWeight.SemiBold), modifier = Modifier.noRippleClickable { onOpenEvent(addedEventKey) })
                }
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(Space.s1)) {
                    // Sized to its label, like the RSVP pills — a single action stretched
                    // edge to edge reads as a form submit, not one option.
                    Row(
                        Modifier.clip(RoundedCornerShape(Radius.full))
                            .background(p.accentViolet)
                            .let { if (busy) it else it.noRippleClickable { onAdd() } }
                            .padding(horizontal = Space.s3, vertical = Space.s2),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("Add to calendar", color = p.onAccent,
                            style = AppFont.ui(13, FontWeight.SemiBold))
                    }
                    if (addError != null) {
                        Text("Couldn't add it: $addError", color = p.accentDanger, style = AppFont.xs)
                    }
                }
            }
        } else if (status != null && !changing) {
            // Answered → compact "You accepted · Change" (mirrors the desktop banner).
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                Icon(SfIcon.vector("checkmark.circle.fill"), null, tint = p.accentSuccess, modifier = Modifier.size(15.dp))
                Text(inviteStatusLabel(status), color = p.textPrimary, style = AppFont.sm)
                Spacer(Modifier.weight(1f))
                Text("Change", color = p.accentViolet, style = AppFont.ui(13, FontWeight.SemiBold),
                    modifier = Modifier.noRippleClickable { onChange() })
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                responses.forEach { (key, label) ->
                    RsvpPill(label, selected = status == key, enabled = !busy) { onRespond(key) }
                }
            }
        }
        if (nearby.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Around this time", color = p.textTertiary, style = AppFont.xs2)
                val fmt = remember { java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault()) }
                nearby.forEach { e ->
                    // Overlaps the invite → warm, like the desktop's `soon` emphasis.
                    val clash = start != null && end != null && e.start != null &&
                        e.start < end && (e.end ?: e.start) > start
                    val tint = if (clash) p.accentWarmBright else p.textSecondary
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                        Text(e.start?.let(fmt::format) ?: "", color = tint, style = AppFont.xs, modifier = Modifier.width(64.dp))
                        Text(e.title, color = if (clash) p.accentWarmBright else p.textPrimary, style = AppFont.xs, maxLines = 1)
                    }
                }
            }
        }
    }
}

/** The device's timed calendar events within ±2h of [invite], minus its own synced
 *  copy. Bounded coarsely by a day either side (`start_at` is stored in mixed offset
 *  forms), then filtered precisely on the parsed dates. Mirrors iOS `loadNearbyEvents`. */
internal fun eventsAround(store: com.inbox2.app.data.InboxStore, invite: com.inbox2.app.model.ClientInvite): List<com.inbox2.app.model.CalendarEvent> {
    val start = invite.startDate ?: return emptyList()
    val end = invite.endDate ?: start
    val lo = java.util.Date(start.time - 2 * 3_600_000)
    val hi = java.util.Date(end.time + 2 * 3_600_000)
    val day = 86_400_000L
    val from = java.time.Instant.ofEpochMilli(lo.time - day).toString()
    val to = java.time.Instant.ofEpochMilli(hi.time + day).toString()
    return store.eventsBetween(from, to, limit = 60).filter { e ->
        val s = e.start ?: return@filter false
        !e.allDay && e.id != invite.matchedEventKey && s < hi && (e.end ?: s) > lo
    }
}

internal fun inviteStatusLabel(s: String): String = when (s) {
    "accepted" -> "You accepted"
    "tentative" -> "You're tentative"
    "declined" -> "You declined"
    else -> s
}

/** One RSVP pill — only the selected answer is tinted (primary); the rest share one
 *  muted neutral (no per-response semantic colors). */
/** Meet-link booking request (docs/Calendar.md) — the web `MeetingRequestBanner`.
 *  Nothing is on the calendar until Accept, which creates the event and mails the
 *  visitor an invite; Decline mails them a no. Final either way: no "Change". */
@Composable
internal fun MeetingRequestBanner(request: com.inbox2.app.model.ClientMeetingRequest, orgId: String, cloud: com.inbox2.app.cloud.CloudSession) {
    val p = theme
    val scope = rememberCoroutineScope()
    var answer by remember(request.key) { mutableStateOf(request.status?.takeIf { it != "pending" }) }
    var busy by remember(request.key) { mutableStateOf(false) }
    var error by remember(request.key) { mutableStateOf<String?>(null) }
    var declining by remember(request.key) { mutableStateOf(false) }
    var reason by remember(request.key) { mutableStateOf("") }
    fun send(accept: Boolean) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            val failed = cloud.answerMeetingRequest(orgId, request.key, accept, reason.trim().ifEmpty { null })
            if (failed == null) answer = if (accept) "accepted" else "declined" else error = failed
            busy = false
        }
    }
    val start = request.start?.let { com.inbox2.app.model.RelativeTime.parse(it) }
    val end = request.end?.let { com.inbox2.app.model.RelativeTime.parse(it) }
    val minutes = if (start != null && end != null) ((end.time - start.time) / 60_000).toInt() else null
    val timeFmt = remember { java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault()) }
    val dayFmt = remember { java.text.SimpleDateFormat("EEE, MMM d", java.util.Locale.getDefault()) }
    // The visitor's own clock, when it isn't ours.
    val theirTime = request.visitorTimezone?.takeIf { it != java.util.TimeZone.getDefault().id && start != null && end != null }?.let { tz ->
        val f = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault()).apply { timeZone = java.util.TimeZone.getTimeZone(tz) }
        "Their time: ${f.format(start!!)} – ${f.format(end!!)}"
    }
    Column(
        Modifier.fillMaxWidth().padding(top = Space.s2)
            .clip(RoundedCornerShape(Radius.md)).background(p.bgElevated).padding(Space.s3),
        verticalArrangement = Arrangement.spacedBy(Space.s3),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            Icon(SfIcon.vector("calendar"), null, tint = p.accentWarmBright,
                modifier = Modifier.padding(top = 1.dp).size(18.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text("${request.name ?: "Someone"} requests ${minutes?.let { "a $it-minute meeting" } ?: "a meeting"}",
                    color = p.textPrimary, style = AppFont.ui(14, FontWeight.SemiBold), maxLines = 2)
                if (start != null && end != null) {
                    Text("${dayFmt.format(start)} · ${timeFmt.format(start)} – ${timeFmt.format(end)}",
                        color = p.textSecondary, style = AppFont.xs)
                }
                theirTime?.let { Text(it, color = p.textTertiary, style = AppFont.xs2) }
            }
        }
        request.note?.takeIf { it.isNotBlank() }?.let {
            Text("\u201C$it\u201D", color = p.textSecondary, style = AppFont.xs)
        }
        val done = answer
        if (done != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                Icon(SfIcon.vector(if (done == "accepted") "checkmark.circle.fill" else "xmark.circle.fill"), null,
                    tint = if (done == "accepted") p.accentSuccess else p.textTertiary, modifier = Modifier.size(15.dp))
                Text(when (done) {
                    "accepted" -> "You accepted. It's on your calendar."
                    "declined" -> "You declined."
                    "expired" -> "This request expired before you answered."
                    else -> done
                }, color = p.textPrimary, style = AppFont.sm)
            }
        } else if (declining) {
            Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2)) {
                if (reason.isEmpty()) Text("Reason (optional, goes in the email)", color = p.textTertiary, style = AppFont.xs)
                androidx.compose.foundation.text.BasicTextField(reason, { reason = it },
                    textStyle = AppFont.xs.copy(color = p.textPrimary),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(p.accentViolet),
                    modifier = Modifier.fillMaxWidth())
            }
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                RsvpPill("Send decline", selected = true, enabled = !busy) { send(false) }
                RsvpPill("Back", selected = false, enabled = !busy) { declining = false }
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                RsvpPill("Accept", selected = true, enabled = !busy) { send(true) }
                RsvpPill("Decline…", selected = false, enabled = !busy) { declining = true }
            }
            Text(when (request.conferenceMode) {
                "meet" -> "Accepting adds a Google Meet link."
                "teams" -> "Accepting adds a Teams link."
                else -> "Not on your calendar yet."
            }, color = p.textTertiary, style = AppFont.xs2)
        }
        error?.let { Text(it, color = p.accentDanger, style = AppFont.xs) }
    }
}

@Composable
internal fun RsvpPill(label: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val p = theme
    Row(
        Modifier.clip(RoundedCornerShape(Radius.full))
            .background(if (selected) p.accentViolet else p.bgSurface)
            .let { if (enabled) it.noRippleClickable { onClick() } else it }
            .padding(horizontal = Space.s3, vertical = Space.s2),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = if (selected) p.onAccent else p.textSecondary,
            style = AppFont.ui(13, if (selected) FontWeight.SemiBold else FontWeight.Medium))
    }
}

/** "Wed, Jun 10 · 9:00 AM – 10:00 AM" / "Wed, Jun 10 · All day" — mirrors the web
 *  formatWhen. Null when the invite carries no start. */
internal fun formatInviteWhen(invite: com.inbox2.app.model.ClientInvite): String? {
    val start = invite.start?.ifBlank { null } ?: return null
    val startParts = com.inbox2.app.model.RelativeTime.longParts(if (invite.allDay) start.take(10) else start, invite.timezone) ?: return null
    if (invite.allDay) return "${startParts.first} · All day"
    val endTime = invite.end?.ifBlank { null }?.let { com.inbox2.app.model.RelativeTime.longParts(it, invite.timezone)?.second }
    return if (endTime != null) "${startParts.first} · ${startParts.second} – $endTime"
    else "${startParts.first} · ${startParts.second}"
}

// DomainCollab moved to DomainCollab.kt (same package).

// replyPrefill / forwardPrefill moved to Quoting.kt (same package).

/** Strip HTML to readable plain text for the "Full message" read-out (mirrors iOS
 *  MessageView.plainText / the core's email_voice::html_to_text): drop script/style/head
 *  blocks, turn block tags into line breaks, remove remaining tags, decode common entities. */
internal fun stripHtmlToText(raw: String): String {
    if (raw.isEmpty()) return ""
    var s = raw
    for (tag in listOf("script", "style", "head"))
        s = s.replace(Regex("(?is)<$tag[^>]*>.*?</$tag>"), " ")
    s = s.replace(Regex("(?i)<(br|/p|/div|/li|/tr|/h[1-6]|/ul|/ol|/blockquote|/section|/article|hr)[^>]*>"), "\n")
    s = s.replace(Regex("<[^>]+>"), " ")
    val entities = mapOf(
        "&nbsp;" to " ", "&amp;" to "&", "&lt;" to "<", "&gt;" to ">", "&quot;" to "\"",
        "&#39;" to "'", "&rsquo;" to "'", "&lsquo;" to "'", "&ldquo;" to "\"", "&rdquo;" to "\"",
        "&mdash;" to "—", "&ndash;" to "–",
    )
    for ((k, v) in entities) s = s.replace(k, v)
    s = s.replace(Regex("[ \\t]+"), " ")
    s = s.replace(Regex("\\n[ \\t]*\\n[ \\t]*\\n+"), "\n\n")
    return s.trim()
}
