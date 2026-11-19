package com.inbox2.app.ui.screens

import com.inbox2.app.ui.components.PillTextButton
import com.inbox2.app.model.DateFmt
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import com.inbox2.app.cloud.CloudZone
import com.inbox2.app.cloud.CloudZoneCategory
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.CalendarEvent
import com.inbox2.app.model.RepeatRule
import com.inbox2.app.model.DayHeader
import com.inbox2.app.model.EVENT_URL_RE
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.DatePick
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.TimePick
import com.inbox2.app.ui.components.creamKeycap
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Event detail + RSVP + edit/delete (iOS EventDetailSheet). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EventDetailSheet(engine: EngineModel, event: CalendarEvent, onDismiss: () -> Unit, onEdit: () -> Unit, onDeleted: () -> Unit,
                     /** Signed-in cloud session — enables the "Prep zone" row (zones are cloud-only). */
                     cloud: com.inbox2.app.cloud.CloudSession? = null) {
    val p = theme
    val scope = rememberCoroutineScope()
    var rsvp by remember { mutableStateOf<String?>(null) }
    var rsvpError by remember { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    // Invite gating matches iOS: organizerLabel falls back to the email — most Google
    // imports carry no display name, and a bare name check hid RSVP for those.
    // Someone else's meeting (the organizer isn't this account) — iOS engine.isInvite.
    val isInvite = remember(event) { engine.isInvite(event) }
    val attendees = remember(event) { event.attendees }
    // Provider-side response already on record — our own attendee row, matched by
    // the account's address. "needsAction" shows as no selection (iOS providerRsvp).
    val providerRsvp = remember(event) {
        val me = engine.accounts.value.firstOrNull { it.id == event.accountKey }?.email?.lowercase()
        attendees.firstOrNull { !me.isNullOrEmpty() && it.email?.lowercase() == me }
            ?.responseStatus?.takeIf { it != "needsAction" }
    }
    val currentRsvp = rsvp ?: providerRsvp

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.bgPanel) {
        Column(Modifier.padding(horizontal = Space.s4).padding(bottom = Space.s8)) {
            Text(event.title, color = p.textPrimary, style = AppFont.title2)
            // One tap into the call — mirrors the desktop event popup's Join button.
            event.meeting?.let { meeting ->
                val uriHandler = LocalUriHandler.current
                PillButton("Join ${meeting.label}", compact = true, icon = "video", logo = meeting.logo,
                    modifier = Modifier.padding(top = Space.s3)) { uriHandler.openUri(meeting.url) }
            }
            DetailLine("clock", "${DayHeader.label(event.dayKey)} · ${event.rangeLabel}")
            // The alarm row only makes sense for a timed meeting that hasn't started (iOS alarmRow).
            val ctxAlarm = androidx.compose.ui.platform.LocalContext.current
            val alarms = com.inbox2.app.notify.MeetingAlarms
            val mutedSet by alarms.muted.collectAsState()
            if (alarms.enabled(ctxAlarm) && !event.allDay && (event.start?.time ?: 0L) > System.currentTimeMillis()) {
                val muted = event.id in mutedSet || alarms.isMuted(ctxAlarm, event.id)
                Row(
                    Modifier.fillMaxWidth().padding(top = Space.s3).noRippleClickable {
                        alarms.setMuted(ctxAlarm, event.id, !muted)
                        scope.launch { alarms.reconcile(ctxAlarm, engine, force = true) }
                    },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s3),
                ) {
                    Icon(SfIcon.vector(if (muted) "bell.slash" else "bell.badge"), null,
                        tint = if (muted) p.textTertiary else p.accentViolet, modifier = Modifier.size(18.dp))
                    Text(if (muted) "Alarm cancelled" else "Alarm ${alarms.leadMinutes(ctxAlarm)} min before",
                        color = if (muted) p.textTertiary else p.textPrimary, style = AppFont.sm, modifier = Modifier.weight(1f))
                    Text(if (muted) "Restore" else "Cancel", color = p.accentViolet, style = AppFont.ui(13, FontWeight.SemiBold))
                }
            }
            event.location?.let { LinkDetailLine("mappin.and.ellipse", it) }
            event.organizerLabel?.let { DetailLine("person.crop.circle", it) }
            event.calendarName?.let { DetailLine("calendar", it) }
            event.detail?.takeIf { it.isNotBlank() }?.let {
                Text(linkified(it, p.accentViolet), color = p.textSecondary, style = AppFont.sm, modifier = Modifier.padding(top = Space.s3))
            }

            if (isInvite) {
                Text("Going?", color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(top = Space.s4, bottom = Space.s2))
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    fun respond(resp: String) {
                        sending = true; rsvpError = false
                        scope.launch {
                            if (engine.respondToEvent(event.accountKey, event.id, resp)) rsvp = resp else rsvpError = true
                            sending = false
                        }
                    }
                    RsvpButton("Yes", "checkmark.circle.fill", p.accentSuccess, selected = currentRsvp == "accepted", enabled = !sending) { respond("accepted") }
                    RsvpButton("Maybe", "questionmark.circle.fill", p.accentAmber, selected = currentRsvp == "tentative", enabled = !sending) { respond("tentative") }
                    RsvpButton("No", "xmark.circle.fill", p.accentDanger, selected = currentRsvp == "declined", enabled = !sending) { respond("declined") }
                }
                if (rsvpError) {
                    Text("Couldn't send your answer. Try again.", color = p.accentDanger, style = AppFont.xs2,
                        modifier = Modifier.padding(top = Space.s2))
                }
            }

            if (attendees.isNotEmpty()) {
                Text(
                    "${attendees.size} participant${if (attendees.size == 1) "" else "s"}",
                    color = p.textTertiary, style = AppFont.xs2,
                    modifier = Modifier.padding(top = Space.s4, bottom = Space.s1),
                )
                attendees.forEach { a ->
                    Row(Modifier.padding(top = Space.s1), verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            SfIcon.vector(a.statusIcon), a.responseStatus,
                            tint = when (a.responseStatus) {
                                "accepted" -> p.accentSuccess
                                "declined" -> p.accentDanger
                                "tentative" -> p.accentAmber
                                else -> p.textTertiary
                            },
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(Modifier.width(Space.s2))
                        Text(a.displayName, color = p.textSecondary, style = AppFont.sm)
                        if (a.isOrganizer) {
                            Spacer(Modifier.width(Space.s2))
                            Box(
                                Modifier.clip(RoundedCornerShape(Radius.full))
                                    .background(p.textTertiary.copy(alpha = 0.16f))
                                    .padding(horizontal = Space.s2, vertical = 2.dp),
                            ) { Text("Organizer", color = p.textTertiary, style = AppFont.xs2) }
                        }
                    }
                }
            }

            if (cloud != null && !event.allDay && (event.start?.time ?: 0L) > System.currentTimeMillis()) PrepZoneRow(cloud, event)

            // Read-only calendars (subscribed feeds, holidays) refuse both; an invite
            // can be removed but not edited — the organizer owns it (iOS toolbar menu).
            if (event.calendarWritable) Row(Modifier.padding(top = Space.s4), horizontalArrangement = Arrangement.spacedBy(Space.s3)) {
                if (!isInvite) Text("Edit", color = p.accentViolet, style = AppFont.md,
                    modifier = Modifier.noRippleClickable { onEdit() })
                Spacer(Modifier.weight(1f))
                Text("Delete event", color = p.accentDanger, style = AppFont.md,
                    modifier = Modifier.noRippleClickable { confirmDelete = true })
            }
        }
    }

    if (confirmDelete) DeleteEventDialog(engine, event, onDismiss = { confirmDelete = false }, onDeleted = onDeleted)
}

/** Delete confirmation, shared by the detail sheet and a row's long-press menu. An
 *  invite asks whether to decline to the organizer first — deleting alone tells
 *  nobody. A refused delete keeps the dialog open with the provider's reason. */
@Composable
fun DeleteEventDialog(engine: EngineModel, event: CalendarEvent, onDismiss: () -> Unit, onDeleted: () -> Unit = {}) {
    val p = theme
    val scope = rememberCoroutineScope()
    val invite = remember(event) { engine.isInvite(event) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    fun run(decline: Boolean) {
        busy = true; error = null
        scope.launch {
            val err = engine.deleteCalendarEvent(event, decline)
            busy = false
            if (err == null) { onDismiss(); onDeleted() } else error = err
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete this event?") },
        text = {
            Column {
                Text(if (invite) "Let ${event.organizerLabel} know you won't attend?" else "\"${event.title}\" will be removed.")
                error?.let { Text(it, color = p.accentDanger, style = AppFont.xs, modifier = Modifier.padding(top = Space.s2)) }
            }
        },
        confirmButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                if (invite) PillTextButton("Delete only", enabled = !busy) { run(decline = false) }
                PillButton(if (invite) "Decline & delete" else "Delete", compact = true, tint = p.accentDanger, busy = busy) { run(decline = invite) }
            }
        },
        dismissButton = { PillTextButton("Cancel", onClick = onDismiss) },
    )
}

@Composable
private fun DetailLine(icon: String, text: String) {
    val p = theme
    Row(Modifier.padding(top = Space.s1), verticalAlignment = Alignment.CenterVertically) {
        Icon(SfIcon.vector(icon), null, tint = p.textTertiary, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(Space.s2))
        Text(text, color = p.textSecondary, style = AppFont.sm)
    }
}

/** DetailLine whose text gets bare http(s) URLs turned into tappable links (iOS linkRow). */
@Composable
private fun LinkDetailLine(icon: String, text: String) {
    val p = theme
    Row(Modifier.padding(top = Space.s1), verticalAlignment = Alignment.CenterVertically) {
        Icon(SfIcon.vector(icon), null, tint = p.textTertiary, modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(Space.s2))
        Text(linkified(text, p.accentViolet), color = p.textSecondary, style = AppFont.sm)
    }
}

/** Bare http(s) URLs in free text (event notes, location) → tappable links — the
 *  Android mirror of iOS `Linkify.attributed`. Trailing sentence punctuation stays
 *  outside the link so "see https://x.com." doesn't capture the period. */
private fun linkified(text: String, color: Color) = buildAnnotatedString {
    var last = 0
    for (m in EVENT_URL_RE.findAll(text)) {
        append(text.substring(last, m.range.first))
        withLink(
            LinkAnnotation.Url(
                m.value,
                TextLinkStyles(SpanStyle(color = color, textDecoration = TextDecoration.Underline)),
            ),
        ) { append(m.value) }
        last = m.range.last + 1
    }
    append(text.substring(last))
}

@Composable
private fun RowScope.RsvpButton(label: String, icon: String, color: Color, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val p = theme
    // Neutral pill with the action color carried by the icon+label; the chosen one
    // fills solid (iOS bordered/borderedProminent pair). Groovebox: a solid pastel
    // with dark ink.
    PillButton(
        label, modifier = Modifier.weight(1f), compact = true, enabled = enabled, icon = icon,
        tint = if (selected) p.groove?.pastel(color) ?: color else p.bgRaised,
        contentColor = if (selected) p.groove?.chipInk ?: Color.White else color,
        onClick = onClick,
    )
}

/** Seed values for a new event drafted by the Bridge voice agent (iOS EventDraftSeed). */
data class EventDraftSeed(
    val title: String,
    val startMs: Long,
    val endMs: Long,
    val location: String = "",
    val attendees: List<String> = emptyList(),
)

/** New/Edit event sheet (iOS NewEventSheet). `seed` prefills a new event drafted by the
 *  Bridge (title/time/location); `editing` opens an existing event for edit. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EventSheet(engine: EngineModel, editing: CalendarEvent?, onDismiss: () -> Unit, seed: EventDraftSeed? = null, initialDay: Date = Date(), inboxAccountKey: String? = null,
               /** A range picked on the day timeline pre-fills a new event. */
               initialRange: LongRange? = null) {
    val p = theme
    val scope = rememberCoroutineScope()
    val defaults = androidx.compose.ui.platform.LocalContext.current.getSharedPreferences("inbox2_defaults", android.content.Context.MODE_PRIVATE)
    // Load the writable-calendar list off the main thread (it's a SQLite JOIN under the
    // store lock — keep it out of the composable body so it can't block the UI thread).
    var calendars by remember { mutableStateOf<List<com.inbox2.app.model.WritableCalendar>>(emptyList()) }
    var calIndex by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) {
        val loaded = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { engine.store.writableCalendars() }
        calendars = loaded
        // Editing: the event's own account. New: the account the inbox is filtered to
        // (its primary sorts first) → the calendar last created on → the first.
        val last = defaults.getString(LAST_CALENDAR_PREF, null)
        calIndex = editing?.let { e -> loaded.indexOfFirst { it.accountKey == e.accountKey }.coerceAtLeast(0) }
            ?: listOf(loaded.indexOfFirst { it.accountKey == inboxAccountKey },
                      loaded.indexOfFirst { it.providerId == last }).firstOrNull { it >= 0 } ?: 0
    }
    // The whole form in one value (iOS NewEventSheet's fields): edits go through copy().
    var draft by remember { mutableStateOf(EventDraft.initial(editing, seed, initialDay, initialRange)) }
    // The guest list the edit opened with: it goes back to the provider only if it
    // changed, so untouched guests keep their RSVPs.
    val initialGuests = remember { draft.attendees }
    val (title, location, allDay, startMs, endMs, attendees) = draft
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var picker by remember { mutableStateOf<EventPicker?>(null) }
    // Repeat. An edited series opens on its own rule, read off the provider
    // (synced rows are expanded instances), so an untouched repeat isn't rewritten.
    var repeat by remember { mutableStateOf(RepeatRule()) }
    var initialRepeat by remember { mutableStateOf(RepeatRule()) }
    var isSeries by remember { mutableStateOf(false) }
    var loadingRule by remember { mutableStateOf(editing != null) }
    var askScope by remember { mutableStateOf(false) }
    /** The rule couldn't be read: whether this is a series is unknown, so the repeat
     *  can't be changed and Save edits this one event only. */
    var ruleUnknown by remember { mutableStateOf(false) }
    var ruleAttempt by remember { mutableStateOf(0) }
    LaunchedEffect(editing?.id, ruleAttempt) {
        if (editing == null) return@LaunchedEffect
        loadingRule = true; ruleUnknown = false
        engine.calendarSeriesRule(editing.accountKey, editing.id)
            .onSuccess { rule ->
                if (rule != null) {
                    initialRepeat = RepeatRule.parse(rule, editing.start?.time ?: startMs); repeat = initialRepeat; isSeries = true
                }
            }
            // Unknown is not "a series": Save must edit this one event, as the
            // sheet says, even if an earlier read had found a rule.
            .onFailure { ruleUnknown = true; isSeries = false; initialRepeat = RepeatRule(); repeat = initialRepeat }
        loadingRule = false
    }
    val repeatTouched = repeat != initialRepeat

    /** `which` is null for a create or a one-off, else this / following / all. */
    fun save(which: String?) {
        busy = true; error = null
        val target = calendars[calIndex]
        // The rule: always on a series-wide edit (the engine reads its absence
        // there as "no longer repeats"), on a create or one-off only when set.
        val rule = repeat.rrule(startMs, allDay)
            ?.takeIf { which == "all" || which == "following" || (which == null && (editing == null || repeatTouched)) }
        val guests = { text: String -> text.split(',', ';').map { it.trim() }.filter { it.contains('@') } }
        val people = guests(attendees)
        // Changed on an edit: the new list, or the explicit "remove everyone" (an
        // empty list on its own means "unchanged" to the engine).
        val changed = editing == null || people.map { it.lowercase() }.toSet() != guests(initialGuests).map { it.lowercase() }.toSet()
        val payload = eventDraftJson(title, location, allDay, startMs, endMs,
            if (changed) people else emptyList(), rule, which, cleared = editing != null && changed && people.isEmpty())
        scope.launch {
            val res = if (editing != null) {
                engine.updateCalendarEvent(editing.accountKey, editing.id, payload)
            } else {
                val r = engine.createCalendarEvent(target.accountKey, target.providerId, payload)
                if (r.first) defaults.edit().putString(LAST_CALENDAR_PREF, target.providerId).apply()
                r
            }
            busy = false
            // The provider's own reason, not a bare "Failed" — an event
            // that didn't appear is otherwise unexplainable.
            if (res.first) onDismiss() else error = res.second.ifEmpty { "Couldn't save the event." }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.bgPanel) {
        // Scrolls: with the repeat controls open the form outgrows a phone
        // screen, and Save sits at the bottom of it.
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = Space.s4).padding(bottom = Space.s8), verticalArrangement = Arrangement.spacedBy(Space.s3)) {
            Text(if (editing != null) "Edit event" else "New event", color = p.textPrimary, style = AppFont.title2)
            SheetField("Title", title) { draft = draft.copy(title = it) }
            // Calendar picker
            if (calendars.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Calendar", color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(80.dp))
                    Text(calendars[calIndex].name, color = p.textPrimary, style = AppFont.sm, modifier = Modifier.weight(1f))
                    // An existing event stays on its calendar (the update ignores it) — iOS shows it read-only.
                    if (calendars.size > 1 && editing == null) Text("Change", color = p.accentViolet, style = AppFont.xs,
                        modifier = Modifier.noRippleClickable {
                            calIndex = (calIndex + 1) % calendars.size })
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("All day", color = p.textTertiary, style = AppFont.sm, modifier = Modifier.weight(1f))
                Switch(colors = com.inbox2.app.ui.components.inboxSwitchColors(), checked = allDay, onCheckedChange = { draft = draft.copy(allDay = it) })
            }
            PickRow("Starts on", SimpleDateFormat("EEE, d MMM yyyy", Locale.getDefault()).format(Date(startMs))) { picker = EventPicker.START_DATE }
            if (!allDay) PickRow("Start", DateFmt.hm(startMs)) { picker = EventPicker.START_TIME }
            // A separate end date makes multi-day events possible (iOS Starts/Ends pickers).
            PickRow("Ends on", SimpleDateFormat("EEE, d MMM yyyy", Locale.getDefault()).format(Date(endMs))) { picker = EventPicker.END_DATE }
            if (!allDay) PickRow("End", DateFmt.hm(endMs)) { picker = EventPicker.END_TIME }
            if (endMs < startMs) Text("The event has to end after it starts.", color = p.accentDanger, style = AppFont.xs2)
            if (loadingRule) Text("Repeat…", color = p.textTertiary, style = AppFont.sm)
            else if (ruleUnknown) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                Text("Couldn't read this event's repeat. Saving now changes this event only.",
                    color = p.textTertiary, style = AppFont.sm, modifier = Modifier.weight(1f))
                PillTextButton("Try again") { ruleAttempt++ }
            }
            else RepeatSection(repeat, startMs, allowCustom = initialRepeat.freq == RepeatRule.Freq.CUSTOM,
                onPickUntil = { picker = EventPicker.UNTIL }) { next ->
                // Back to "custom" restores the rule as it was set elsewhere.
                repeat = if (next.freq == RepeatRule.Freq.CUSTOM) initialRepeat else next
            }
            SheetField("Location", location) { draft = draft.copy(location = it) }
            SheetField("With", attendees) { draft = draft.copy(attendees = it) }
            error?.let { Text(it, color = p.accentDanger, style = AppFont.xs) }

            PillButton(if (busy) "Saving…" else "Save", busy = busy,
                enabled = title.isNotBlank() && calendars.isNotEmpty() && endMs >= startMs && !loadingRule) {
                if (isSeries) askScope = true else save(null)
            }
        }
    }

    // Google/Outlook's question for an edited repeating event. A new rule is a
    // series change, so "This event" isn't offered with one.
    if (askScope) AlertDialog(
        onDismissRequest = { askScope = false },
        title = { Text("Save recurring event") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                if (!repeatTouched) PillTextButton("This event") { askScope = false; save("this") }
                PillTextButton("This and following events") { askScope = false; save("following") }
                PillTextButton("All events") { askScope = false; save("all") }
            }
        },
        confirmButton = {},
        dismissButton = { PillTextButton("Cancel") { askScope = false } },
    )

    when (picker) {
        EventPicker.START_DATE -> DatePick(startMs) { picked ->
            picker = null
            if (picked != null) {
                val shift = dayOnly(picked) - dayOnly(startMs)
                draft = draft.copy(startMs = startMs + shift, endMs = endMs + shift)
            }
        }
        // Moving the start drags the end with it, keeping the meeting's length (the
        // date picker above already shifts both) — otherwise a later start leaves an
        // end before it, which the providers reject.
        EventPicker.START_TIME -> TimePick(startMs) { picked ->
            picker = null
            if (picked != null) {
                val length = (endMs - startMs).coerceAtLeast(0)
                draft = draft.copy(startMs = picked, endMs = picked + if (length > 0) length else 3_600_000)
            }
        }
        EventPicker.END_TIME -> TimePick(endMs) { picker = null; if (it != null) draft = draft.copy(endMs = it) }
        EventPicker.END_DATE -> DatePick(endMs) { picked -> picker = null; if (picked != null) draft = draft.copy(endMs = endMs + dayOnly(picked) - dayOnly(endMs)) }
        EventPicker.UNTIL -> DatePick(repeat.until.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()) { picked ->
            picker = null
            if (picked != null) repeat = repeat.copy(until = Instant.ofEpochMilli(picked).atZone(ZoneId.systemDefault()).toLocalDate())
        }
        null -> {}
    }
}

/** The event form's values (iOS NewEventSheet state), one immutable value per edit. */
internal data class EventDraft(
    val title: String,
    val location: String,
    val allDay: Boolean,
    val startMs: Long,
    val endMs: Long,
    /** "With": comma/semicolon-separated emails — Bridge drafts arrive with names or
     *  addresses already resolved against contacts (iOS attendees field). */
    val attendees: String,
) {
    companion object {
        fun initial(editing: CalendarEvent?, seed: EventDraftSeed?, initialDay: Date, initialRange: LongRange?): EventDraft {
            // The next top-of-hour (at least 09:00) on the day in view — iOS NewEventSheet.
            val defaultStart = defaultStartOn(initialDay)
            return EventDraft(
                title = editing?.title ?: seed?.title ?: "",
                location = editing?.location ?: seed?.location ?: "",
                allDay = editing?.allDay ?: false,
                startMs = editing?.start?.time ?: seed?.startMs ?: initialRange?.first ?: defaultStart,
                endMs = editing?.end?.time ?: seed?.endMs ?: initialRange?.last ?: (defaultStart + 3600_000),
                attendees = editing?.attendees?.mapNotNull { it.email }?.joinToString(", ") ?: seed?.attendees?.joinToString(", ") ?: "",
            )
        }
    }
}

/** Which picker dialog the event sheet has open. */
private enum class EventPicker { START_DATE, START_TIME, END_DATE, END_TIME, UNTIL }

/** The event sheet's Repeat block: frequency chips, every-N, weekday chips for a
 *  weekly repeat, and how it ends. [onChange] gets the whole new rule. */
@Composable
private fun RepeatSection(repeat: RepeatRule, startMs: Long, allowCustom: Boolean, onPickUntil: () -> Unit,
                          onChange: (RepeatRule) -> Unit) {
    val p = theme
    Column(verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        Text("Repeat", color = p.textTertiary, style = AppFont.sm)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            RepeatRule.Freq.entries.filter { it != RepeatRule.Freq.CUSTOM || allowCustom }.forEach { f ->
                ChoiceChip(if (f == RepeatRule.Freq.NONE) "Never" else f.label, repeat.freq == f, null) { onChange(repeat.copy(freq = f)) }
            }
        }
        if (repeat.freq == RepeatRule.Freq.NONE || repeat.freq == RepeatRule.Freq.CUSTOM) return@Column
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
            Text(if (repeat.interval == 1) "Every ${repeat.freq.unit}" else "Every ${repeat.interval} ${repeat.freq.unit}s",
                color = p.textPrimary, style = AppFont.sm, modifier = Modifier.weight(1f))
            PillTextButton("−", enabled = repeat.interval > 1) { onChange(repeat.copy(interval = repeat.interval - 1)) }
            PillTextButton("+") { onChange(repeat.copy(interval = repeat.interval + 1)) }
        }
        if (repeat.freq == RepeatRule.Freq.WEEKLY) {
            val active = repeat.activeDays(startMs)
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s1)) {
                RepeatRule.WEEKDAYS.forEach { (code, short) ->
                    val on = code in active
                    // Unticking the last day leaves the start's own weekday.
                    val spoken = java.time.DayOfWeek.entries[RepeatRule.WEEKDAYS.indexOfFirst { it.first == code }]
                        .getDisplayName(java.time.format.TextStyle.FULL, Locale.getDefault())
                    ChoiceChip(short, on, null, spoken = spoken) { onChange(repeat.copy(days = if (on) active - code else active + code)) }
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Space.s2), verticalAlignment = Alignment.CenterVertically) {
            Text("Ends", color = p.textTertiary, style = AppFont.sm)
            RepeatRule.Ends.entries.forEach { e ->
                ChoiceChip(e.label, repeat.ends == e, null) {
                    // "On date" opens on the start's day, never before it.
                    val first = RepeatRule.localDate(startMs)
                    onChange(repeat.copy(ends = e, until = if (e == RepeatRule.Ends.ON && repeat.until < first) first else repeat.until))
                }
            }
        }
        when (repeat.ends) {
            RepeatRule.Ends.ON -> PickRow("Until", repeat.until.format(java.time.format.DateTimeFormatter.ofPattern("EEE, d MMM yyyy", Locale.getDefault())), onPickUntil)
            RepeatRule.Ends.AFTER -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                Text(if (repeat.count == 1) "1 time" else "${repeat.count} times", color = p.textPrimary, style = AppFont.sm, modifier = Modifier.weight(1f))
                PillTextButton("−", enabled = repeat.count > 1) { onChange(repeat.copy(count = repeat.count - 1)) }
                PillTextButton("+") { onChange(repeat.copy(count = repeat.count + 1)) }
            }
            RepeatRule.Ends.NEVER -> {}
        }
    }
}

/** "Prep zone" in the event sheet: a zone named "Prep: <title>" ending as the meeting
 *  starts, in the "Prep" category when the user still has one. */
@Composable
private fun PrepZoneRow(cloud: com.inbox2.app.cloud.CloudSession, event: CalendarEvent) {
    val p = theme
    val scope = rememberCoroutineScope()
    val categories by cloud.zoneCategories.collectAsState()
    var minutes by remember { mutableStateOf(60) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    val startMs = event.start!!.time
    Text("Prep zone", color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(top = Space.s4, bottom = Space.s2))
    Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
        listOf(30 to "30 min", 60 to "1 hour", 120 to "2 hours").forEach { (m, label) ->
            ChoiceChip(label, selected = minutes == m, dot = null) { minutes = m; result = null }
        }
    }
    Row(Modifier.padding(top = Space.s3)) {
        Text(if (busy) "Adding…" else "Add prep zone", color = p.accentViolet, style = AppFont.ui(14, FontWeight.SemiBold),
            modifier = Modifier.noRippleClickable(enabled = !busy) {
                busy = true
                scope.launch {
                    val prep = categories.firstOrNull { it.name.equals("Prep", ignoreCase = true) }
                    // Anchored: the zone moves with the meeting if it's rescheduled.
                    val err = cloud.saveZone(null, "Prep: ${event.title}", null, prep?.id,
                        startMs - minutes * 60_000L, startMs, notify = true,
                        anchorEventId = event.id, anchorMinutes = minutes)
                    busy = false
                    result = err ?: "Prep zone added"
                }
            })
    }
    result?.let { Text(it, color = if (it == "Prep zone added") p.accentSuccess else p.accentDanger, style = AppFont.xs2,
        modifier = Modifier.padding(top = Space.s2)) }
}

/** Pill chip with an optional coloured dot (zone categories, prep lengths).
 *  [spoken] replaces a terse label for screen readers ("Tuesday" for "T"). */
@Composable
private fun ChoiceChip(label: String, selected: Boolean, dot: Color?, spoken: String? = null, onClick: () -> Unit) {
    val p = theme
    val tint = dot ?: p.accentViolet
    val key = p.groove?.takeIf { selected }   // Groovebox: the chosen option is a cream keycap
    Row(
        (if (key != null) Modifier.creamKeycap(key) else Modifier)
            .clip(RoundedCornerShape(Radius.full))
            .then(if (key == null) Modifier.background(if (selected) tint.copy(alpha = 0.22f) else p.bgRaised)
                .border(1.dp, if (selected) tint.copy(alpha = 0.7f) else p.borderDefault, RoundedCornerShape(Radius.full)) else Modifier)
            .noRippleClickable { onClick() }
            // A choice reads as one, with its on/off state, not as bare text.
            .semantics(mergeDescendants = true) {
                this.selected = selected
                spoken?.let { contentDescription = it }
            }
            .padding(horizontal = Space.s3, vertical = 6.dp)
            .then(if (key != null) Modifier.padding(bottom = 3.dp) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        dot?.let { Box(Modifier.size(7.dp).clip(androidx.compose.foundation.shape.CircleShape).background(it)); Spacer(Modifier.width(6.dp)) }
        Text(label, color = if (selected) p.groove?.creamInk ?: p.textPrimary else p.textSecondary, style = AppFont.xs)
    }
}

/** New/edit zone sheet. A zone never marks the user busy — it's a focus block with an
 *  optional start alert (notify). [editing] null = new, starting on [initialDay]. A zone
 *  may run past midnight (at most 24h) and repeat; editing a repeat edits the series. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ZoneSheet(cloud: com.inbox2.app.cloud.CloudSession, editing: com.inbox2.app.cloud.CloudZone?, initialDay: Date, onDismiss: () -> Unit, initialRange: LongRange? = null) {
    val p = theme
    val scope = rememberCoroutineScope()
    val categories by cloud.zoneCategories.collectAsState()
    var name by remember { mutableStateOf(editing?.name ?: "") }
    var note by remember { mutableStateOf(editing?.note ?: "") }
    var categoryId by remember { mutableStateOf(editing?.categoryId) }
    // Nothing picked yet on a new zone: the first category (Deep work by default).
    LaunchedEffect(categories) { if (editing == null && categoryId == null) categoryId = categories.firstOrNull()?.id }
    val defaultStart = remember { defaultStartOn(initialDay) }
    var startMs by remember { mutableStateOf(editing?.startMs ?: initialRange?.first ?: defaultStart) }
    var endMs by remember { mutableStateOf(editing?.endMs ?: initialRange?.last ?: (defaultStart + 2 * 3_600_000)) }
    var notify by remember { mutableStateOf(editing?.notify ?: true) }
    var repeat by remember { mutableStateOf(editing?.repeat ?: CloudZone.REPEAT_NONE) }
    var repeatUntil by remember { mutableStateOf(editing?.repeatUntil) } // YYYY-MM-DD
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var editCategories by remember { mutableStateOf(false) }
    // Which picker is open: "startDate" | "startTime" | "endDate" | "endTime" | "until".
    var picking by remember { mutableStateOf<String?>(null) }
    val series = editing?.repeating == true

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.bgPanel) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = Space.s4).padding(bottom = Space.s8),
            verticalArrangement = Arrangement.spacedBy(Space.s3)) {
            Text(if (editing != null) "Edit zone" else "New zone", color = p.textPrimary, style = AppFont.title2)
            if (series) Text("Changes apply to all repeats.", color = p.textTertiary, style = AppFont.xs2)
            SheetField("Name", name) { name = it }
            SheetField("Note", note, maxLines = 4) { note = it }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                categories.forEach { c ->
                    // Tapping the selected chip again clears it — an uncategorised zone (iOS).
                    ChoiceChip(c.name, selected = c.id == categoryId, dot = p.zone(c.color)) { categoryId = if (categoryId == c.id) null else c.id }
                }
            }
            Text("Edit categories", color = p.accentViolet, style = AppFont.xs,
                modifier = Modifier.noRippleClickable { editCategories = true })
            DateTimeRow("Starts", startMs, onDate = { picking = "startDate" }, onTime = { picking = "startTime" })
            DateTimeRow("Ends", endMs, onDate = { picking = "endDate" }, onTime = { picking = "endTime" })
            if (dayOnly(endMs) > dayOnly(startMs)) Text("next day", color = p.textTertiary, style = AppFont.xs2, modifier = Modifier.padding(start = 80.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Repeat", color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(80.dp))
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    CloudZone.REPEATS.forEach { (key, label) ->
                        ChoiceChip(label, selected = repeat == key, dot = null) { repeat = key }
                    }
                }
            }
            if (repeat != CloudZone.REPEAT_NONE) Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Until", color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(80.dp))
                Text(repeatUntil?.let { java.time.LocalDate.parse(it).format(DateTimeFormatter.ofPattern("EEE, d MMM yyyy", Locale.getDefault())) } ?: "Forever",
                    color = p.textPrimary, style = AppFont.sm,
                    modifier = Modifier.weight(1f).noRippleClickable { picking = "until" })
                if (repeatUntil != null) Text("Clear", color = p.accentViolet, style = AppFont.xs,
                    modifier = Modifier.noRippleClickable { repeatUntil = null })
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Zone alert", color = p.textTertiary, style = AppFont.sm, modifier = Modifier.weight(1f))
                Switch(colors = com.inbox2.app.ui.components.inboxSwitchColors(), checked = notify, onCheckedChange = { notify = it })
            }
            Text("Zones never mark you busy. People can still book this time.", color = p.textTertiary, style = AppFont.xs2)
            error?.let { Text(it, color = p.accentDanger, style = AppFont.xs) }
            PillButton(if (busy) "Saving…" else "Save", busy = busy, enabled = name.isNotBlank()) {
                if (endMs <= startMs) { error = "The zone has to end after it starts."; return@PillButton }
                if (endMs - startMs > DAY_MS) { error = "A zone can last at most 24 hours."; return@PillButton }
                busy = true; error = null
                scope.launch {
                    val until = repeatUntil.takeIf { repeat != CloudZone.REPEAT_NONE }
                    // Moving a prep zone by hand unhooks it from its meeting, or the next
                    // reconcile would snap it back (iOS clearAnchor).
                    val retimed = editing != null && (startMs != editing.startMs || endMs != editing.endMs)
                    val err = cloud.saveZone(editing?.id, name.trim(), note.trim().ifEmpty { null }, categoryId, startMs, endMs, notify,
                        repeat = repeat, repeatUntil = until, clearAnchor = retimed && editing?.anchorEventId != null)
                    busy = false
                    if (err == null) onDismiss() else error = err
                }
            }
            if (editing != null) Text(if (series) "Delete all repeats" else "Delete zone", color = p.accentDanger, style = AppFont.md,
                modifier = Modifier.noRippleClickable { confirmDelete = true })
        }
    }
    if (editCategories) ZoneCategoriesSheet(cloud) { editCategories = false }

    // Moving the start keeps the zone's length, as the event sheet does.
    fun moveStart(to: Long) { val len = endMs - startMs; startMs = to; endMs = to + if (len > 0) len else 3_600_000 }
    when (picking) {
        "startDate" -> DatePick(startMs) { picking = null; if (it != null) moveStart(startMs + dayOnly(it) - dayOnly(startMs)) }
        "startTime" -> TimePick(startMs) { picking = null; if (it != null) moveStart(it) }
        "endDate" -> DatePick(endMs) { picking = null; if (it != null) endMs += dayOnly(it) - dayOnly(endMs) }
        // An end time at or before the start means tomorrow: an overnight zone.
        "endTime" -> TimePick(endMs) { picking = null; if (it != null) {
            val sameDay = it + dayOnly(startMs) - dayOnly(it)
            endMs = if (sameDay > startMs) sameDay else sameDay + DAY_MS
        } }
        // The picker hands back UTC midnight of the chosen day.
        "until" -> DatePick(repeatUntil?.let { java.time.LocalDate.parse(it).toEpochDay() * DAY_MS } ?: startMs) {
            picking = null; if (it != null) repeatUntil = java.time.LocalDate.ofEpochDay(it / DAY_MS).toString()
        }
    }
    if (confirmDelete && editing != null) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text(if (series) "Delete all repeats?" else "Delete this zone?") },
        text = { Text(if (series) "Every repeat of \"${editing.name}\" will be removed." else "\"${editing.name}\" will be removed.") },
        confirmButton = {
            PillButton(if (series) "Delete all repeats" else "Delete", compact = true, tint = p.accentDanger, busy = busy) {
                busy = true
                scope.launch {
                    val err = cloud.deleteZone(editing.id)
                    busy = false; confirmDelete = false
                    if (err == null) onDismiss() else error = err
                }
            }
        },
        dismissButton = { PillTextButton("Cancel") { confirmDelete = false } },
    )
}

private const val DAY_MS = 86_400_000L

/** Zone categories: list, add, rename, recolour (the 6 palette keys), delete. Deleting
 *  one leaves its zones uncategorised. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ZoneCategoriesSheet(cloud: com.inbox2.app.cloud.CloudSession, onDismiss: () -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    val categories by cloud.zoneCategories.collectAsState()
    // The category being edited: null = the list; an empty id = a new one.
    var editing by remember { mutableStateOf<CloudZoneCategory?>(null) }
    var name by remember { mutableStateOf("") }
    var color by remember { mutableStateOf("blue") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    fun open(c: CloudZoneCategory) { editing = c; name = c.name; color = c.color; error = null }

    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = p.bgPanel) {
        Column(Modifier.padding(horizontal = Space.s4).padding(bottom = Space.s8), verticalArrangement = Arrangement.spacedBy(Space.s3)) {
            val cat = editing
            if (cat == null) {
                Text("Zone categories", color = p.textPrimary, style = AppFont.title2)
                categories.forEach { c ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(p.bgRaised)
                        .noRippleClickable { open(c) }.padding(Space.s3), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(10.dp).clip(androidx.compose.foundation.shape.CircleShape).background(p.zone(c.color)))
                        Spacer(Modifier.width(Space.s3))
                        Text(c.name, color = p.textPrimary, style = AppFont.sm, modifier = Modifier.weight(1f))
                        Icon(SfIcon.vector("trash"), "Delete category", tint = p.textTertiary,
                            modifier = Modifier.padding(end = Space.s3).size(16.dp).noRippleClickable { open(c); confirmDelete = true })
                        Icon(SfIcon.vector("chevron.right"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
                    }
                }
                Text("Add category", color = p.accentViolet, style = AppFont.ui(14, FontWeight.SemiBold),
                    modifier = Modifier.noRippleClickable {
                        open(CloudZoneCategory("", "", CloudZoneCategory.COLORS[categories.size % CloudZoneCategory.COLORS.size]))
                    })
            } else {
                Text(if (cat.id.isEmpty()) "New category" else "Edit category", color = p.textPrimary, style = AppFont.title2)
                SheetField("Name", name) { name = it }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Colour", color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(80.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                        CloudZoneCategory.COLORS.forEach { key ->
                            val shape = androidx.compose.foundation.shape.CircleShape
                            Box(Modifier.size(30.dp).clip(shape)
                                .border(2.dp, if (key == color) p.textPrimary else Color.Transparent, shape)
                                .padding(4.dp).clip(shape).background(p.zone(key))
                                .noRippleClickable { color = key })
                        }
                    }
                }
                error?.let { Text(it, color = p.accentDanger, style = AppFont.xs) }
                PillButton(if (busy) "Saving…" else "Save", busy = busy, enabled = name.isNotBlank()) {
                    busy = true; error = null
                    scope.launch {
                        val err = cloud.saveZoneCategory(cat.id.ifEmpty { null }, name.trim(), color)
                        busy = false
                        if (err == null) editing = null else error = err
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s5)) {
                    Text("Back", color = p.textSecondary, style = AppFont.md, modifier = Modifier.noRippleClickable { editing = null })
                    if (cat.id.isNotEmpty()) Text("Delete category", color = p.accentDanger, style = AppFont.md,
                        modifier = Modifier.noRippleClickable { confirmDelete = true })
                }
            }
        }
    }
    val cat = editing
    if (confirmDelete && cat != null) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text("Delete \"${cat.name}\"?") },
        text = { Text("Its zones stay on your calendar, without a category.") },
        confirmButton = {
            PillButton("Delete", compact = true, tint = p.accentDanger, busy = busy) {
                busy = true
                scope.launch {
                    val err = cloud.deleteZoneCategory(cat.id)
                    busy = false; confirmDelete = false
                    if (err == null) editing = null else error = err
                }
            }
        },
        dismissButton = { PillTextButton("Cancel") { confirmDelete = false } },
    )
}

@Composable
private fun DateTimeRow(label: String, ms: Long, onDate: () -> Unit, onTime: () -> Unit) {
    val p = theme
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(80.dp))
        Text(SimpleDateFormat("EEE, d MMM yyyy", Locale.getDefault()).format(Date(ms)), color = p.textPrimary, style = AppFont.sm,
            modifier = Modifier.weight(1f).noRippleClickable { onDate() })
        Text(DateFmt.hm(ms), color = p.textPrimary, style = AppFont.sm,
            modifier = Modifier.clip(RoundedCornerShape(Radius.md)).background(p.bgInput)
                .noRippleClickable { onTime() }.padding(horizontal = Space.s2, vertical = Space.s1))
    }
}

@Composable
private fun SheetField(label: String, value: String, maxLines: Int = 1, onChange: (String) -> Unit) {
    val p = theme
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(80.dp))
        Box(Modifier.weight(1f).clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2 + 2.dp)) {
            BasicTextField(value, onChange, singleLine = maxLines == 1, maxLines = maxLines,
                textStyle = AppFont.sm.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun PickRow(label: String, value: String, onClick: () -> Unit) {
    val p = theme
    Row(Modifier.noRippleClickable { onClick() },
        verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = p.textTertiary, style = AppFont.sm, modifier = Modifier.width(80.dp))
        Text(value, color = p.textPrimary, style = AppFont.sm)
        Spacer(Modifier.weight(1f))
        Icon(SfIcon.vector("chevron.right"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
    }
}

private const val LAST_CALENDAR_PREF = "last_calendar_provider_id"

private fun nextHour(): Long = Calendar.getInstance().apply {
    add(Calendar.HOUR_OF_DAY, 1); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis
internal fun dayOnly(ms: Long): Long = Calendar.getInstance().apply {
    timeInMillis = ms; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis

/** EventDraft JSON the Rust core expects (calendar.rs EventDraft). */
private fun eventDraftJson(title: String, location: String, allDay: Boolean, startMs: Long, endMs: Long, attendees: List<String> = emptyList(),
                           recurrence: String? = null, scope: String? = null, cleared: Boolean = false): String {
    val o = JSONObject().put("title", title)
    if (cleared) o.put("attendees_cleared", true)
    recurrence?.let { o.put("recurrence", it) }
    scope?.let { o.put("scope", it) }
    if (location.isNotBlank()) o.put("location", location)
    o.put("all_day", allDay)
    o.put("timezone", ZoneId.systemDefault().id)
    if (allDay) {
        val d = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        o.put("start_at", d.format(Date(startMs)))
        o.put("end_at", d.format(Date(maxOf(endMs, startMs + 86_400_000))))
    } else {
        o.put("start_at", DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(Instant.ofEpochMilli(startMs).atZone(ZoneId.systemDefault())))
        o.put("end_at", DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(Instant.ofEpochMilli(endMs).atZone(ZoneId.systemDefault())))
    }
    o.put("attendees", JSONArray().apply { attendees.forEach { put(it) } })
    return o.toString()
}

/** New-event/zone default start: the next top-of-hour, at least 09:00, on [day] (iOS). */
private fun defaultStartOn(day: Date): Long = Calendar.getInstance().apply {
    val hour = (Calendar.getInstance().get(Calendar.HOUR_OF_DAY) + 1).coerceAtLeast(9).coerceAtMost(23)
    time = day; set(Calendar.HOUR_OF_DAY, hour); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis
