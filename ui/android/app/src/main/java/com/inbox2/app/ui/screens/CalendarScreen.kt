package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.cloud.CloudZone
import com.inbox2.app.cloud.CloudZoneCategory
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.CalendarEvent
import com.inbox2.app.model.DayHeader
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.ChannelColor
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.colorHex
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.EmptyState
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SegmentedTabs
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.insetCard
import com.inbox2.app.ui.components.creamKeycap
import com.inbox2.app.ui.components.groovePanel
import androidx.compose.ui.graphics.SolidColor
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Calendar (iOS CalendarView): Upcoming agenda + a month grid (per-day dots, day
 *  detail), event detail with RSVP + edit/delete, and a new/edit event sheet. */
@Composable
fun CalendarScreen(
    engine: EngineModel,
    /** A meeting the Bridge voice agent drafted — opens the create sheet prefilled. */
    seedEvent: EventDraftSeed? = null,
    onSeedConsumed: () -> Unit = {},
    /** An invite-banner tap: open this event's detail, month/day anchored to it
     *  (iOS openPendingInviteEvent). */
    openEventKey: String? = null,
    onOpenEventConsumed: () -> Unit = {},
    /** The account the inbox is filtered to (null = Unified) — new events default to it. */
    inboxAccountKey: String? = null,
    /** Zones live on the inbox2 account: null (or signed out) hides every zone surface. */
    cloud: CloudSession? = null,
) {
    val p = theme
    val dataVersion by engine.dataVersion.collectAsState()
    var tab by remember { mutableStateOf("Upcoming") }
    var events by remember { mutableStateOf<List<CalendarEvent>>(emptyList()) }
    var monthEvents by remember { mutableStateOf<List<CalendarEvent>>(emptyList()) }
    var monthAnchor by remember { mutableStateOf(startOfMonth(Date())) }
    var selectedDay by remember { mutableStateOf(startOfDay(Date())) }
    var detail by remember { mutableStateOf<CalendarEvent?>(null) }
    var editing by remember { mutableStateOf<CalendarEvent?>(null) }
    var creating by remember { mutableStateOf(false) }
    var draftSeed by remember { mutableStateOf<EventDraftSeed?>(null) }
    // Zones (cloud-only): the calendar fetches the window it shows — today onward for
    // the agenda plus the month grid's three months — and re-fetches on any zone edit.
    val cloudUser = cloud?.user?.collectAsState()?.value
    val zonesOn = cloud != null && cloudUser != null
    val zoneRev = cloud?.zoneRevision?.collectAsState()?.value ?: 0
    val zoneCats = cloud?.zoneCategories?.collectAsState()?.value.orEmpty()
    var zones by remember { mutableStateOf<List<CloudZone>>(emptyList()) }
    var zoneEditing by remember { mutableStateOf<CloudZone?>(null) }
    var zoneCreating by remember { mutableStateOf(false) }
    var addMenu by remember { mutableStateOf(false) }
    // Day timeline + create chooser (iOS b3730456): a drag range pre-fills the next sheet;
    // Block time (org-scoped "not available" windows) is created at once, no sheet.
    var createRange by remember { mutableStateOf<LongRange?>(null) }
    var showChooser by remember { mutableStateOf(false) }
    var pendingBlockRemove by remember { mutableStateOf<com.inbox2.app.cloud.CloudBlockedTime?>(null) }
    var actionError by remember { mutableStateOf<String?>(null) }
    val cloudRev = cloud?.revision?.collectAsState()?.value ?: 0
    var blocks by remember { mutableStateOf<List<com.inbox2.app.cloud.CloudBlockedTime>>(emptyList()) }
    LaunchedEffect(zonesOn, cloudRev, selectedDay) {
        if (!zonesOn) { blocks = emptyList(); return@LaunchedEffect }
        val from = dayStartMs(selectedDay.time); val to = from + 86_400_000L
        blocks = cloud.blockedTimes(isoOf(from), isoOf(to))
    }
    val scope = rememberCoroutineScope()
    LaunchedEffect(zonesOn, zoneRev, monthAnchor) {
        if (!zonesOn) { zones = emptyList(); return@LaunchedEffect }
        val today = startOfDay(Date())
        val from = minOf(addDays(today, -1).time, addMonths(monthAnchor, -1).time)
        val to = maxOf(addDays(today, 90).time, addMonths(monthAnchor, 2).time)
        zones = cloud.zonesBetween(from, to)
    }
    val categoryOf = { z: CloudZone -> zoneCats.firstOrNull { it.id == z.categoryId } }
    // Prep zones follow their meeting when it moves (only for events loaded here).
    LaunchedEffect(zones, events) { if (zonesOn) cloud.reconcileAnchoredZones(zones, events) }

    // The Bridge handed us a drafted meeting — open the create sheet prefilled.
    LaunchedEffect(seedEvent) { seedEvent?.let { draftSeed = it; creating = true } }
    LaunchedEffect(openEventKey, dataVersion) {
        val key = openEventKey ?: return@LaunchedEffect
        val ev = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { engine.store.event(key) }
        onOpenEventConsumed()
        ev?.let { e ->
            e.start?.let { s -> selectedDay = startOfDay(s); monthAnchor = startOfMonth(s) }
            detail = e
        }
    }

    LaunchedEffect(dataVersion) {
        val fromISO = isoOffset(startOfDay(Date()))
        events = withContext(Dispatchers.IO) { engine.store.upcomingEvents(fromISO) }
    }
    // Meeting-load chart (iOS UpcomingLoadChart): a ±30-day window — the agenda
    // list above only has events from today on.
    var chartEvents by remember { mutableStateOf<List<CalendarEvent>>(emptyList()) }
    var chartDay by remember { mutableStateOf<Date?>(null) }
    val accounts by engine.accounts.collectAsState()
    val channelOrder = remember(accounts) { accounts.map { it.id } }
    LaunchedEffect(dataVersion) {
        val today = startOfDay(Date())
        chartEvents = withContext(Dispatchers.IO) {
            engine.store.eventsBetween(isoOffset(addDays(today, -30)), isoOffset(addDays(today, 31)))
        }
    }
    LaunchedEffect(dataVersion, monthAnchor) {
        val from = isoOffset(addMonths(monthAnchor, -1))
        val to = isoOffset(addMonths(monthAnchor, 2))
        monthEvents = withContext(Dispatchers.IO) { engine.store.eventsBetween(from, to) }
    }
    // Writable calendars gate the "+" / create chooser. One read off the main thread
    // (a SQLite JOIN under the store lock) shared by the header, Day view and chooser.
    var writable by remember { mutableStateOf<List<com.inbox2.app.model.WritableCalendar>>(emptyList()) }
    LaunchedEffect(dataVersion) { writable = withContext(Dispatchers.IO) { engine.store.writableCalendars() } }

    androidx.compose.runtime.CompositionLocalProvider(LocalChannelOrder provides channelOrder) {
    Box(Modifier.fillMaxSize().background(p.bgBase)) {
        Column(Modifier.fillMaxSize()) {
            ScreenHeader("Calendar") {
                if (writable.isNotEmpty() || zonesOn) {
                    // Signed in: + opens the create chooser (event / zone); otherwise straight to a new event.
                    Icon(SfIcon.vector("plus"), "New", tint = p.accentViolet,
                        modifier = Modifier.size(24.dp).noRippleClickable { createRange = null; if (zonesOn) showChooser = true else creating = true })
                }
            }
            SegmentedTabs(listOf("Upcoming", "Day", "Calendar"), tab, { tab = it }, Modifier.padding(horizontal = Space.s4, vertical = Space.s2))

            // Groovebox: the tab's content is framed on one solid panel.
            val body: @Composable () -> Unit = {
            if (tab == "Day") {
                CalendarDayView(
                    engine, day = selectedDay, onDayChange = { selectedDay = it; monthAnchor = startOfMonth(it) },
                    channelOrder = channelOrder, zones = zones, categoryOf = categoryOf, blocks = blocks,
                    highlight = if (showChooser) createRange else null,
                    onSelect = { detail = it }, onEditZone = { zoneEditing = it },
                    onSelectBlock = { pendingBlockRemove = it },
                    onCreate = { range ->
                        if (writable.isNotEmpty() || zonesOn) { createRange = range; showChooser = true }
                    },
                )
            } else if (tab == "Upcoming") {
                AgendaList(
                    engine, events, onTap = { detail = it }, onEdit = { editing = it },
                    zones = zones, categoryOf = categoryOf, onOpenZone = { zoneEditing = it },
                    chartEvents = chartEvents, channelOrder = channelOrder,
                    chartDay = chartDay,
                    onSelectDay = { day ->
                        chartDay = if (chartDay != null && startOfDay(day) == startOfDay(chartDay!!)) null else day
                    },
                )
            } else {
                MonthGrid(
                    engine, monthAnchor, selectedDay, monthEvents,
                    onPrev = { monthAnchor = addMonths(monthAnchor, -1) },
                    onNext = { monthAnchor = addMonths(monthAnchor, 1) },
                    onToday = { monthAnchor = startOfMonth(Date()); selectedDay = startOfDay(Date()) },
                    onPickDay = { selectedDay = it },
                    onTapEvent = { detail = it },
                    onEditEvent = { editing = it },
                    zones = zones, categoryOf = categoryOf, onOpenZone = { zoneEditing = it },
                )
            }
            }
            if (p.groove != null) Box(Modifier.weight(1f).groovePanel()) { body() } else body()
        }
    }
    }

    if (showChooser) {
        CreateChoiceSheet(
            range = createRange,
            kinds = listOfNotNull(
                if (writable.isNotEmpty()) CreateKind.EVENT else null,
                if (zonesOn) CreateKind.ZONE else null,
                // Drag ranges only ("+" has no range) — created at once, no sheet.
                if (zonesOn && createRange != null) CreateKind.BLOCK else null,
            ),
            onPick = { kind ->
                showChooser = false
                when (kind) {
                    CreateKind.EVENT -> creating = true
                    CreateKind.ZONE -> zoneCreating = true
                    CreateKind.BLOCK -> createRange?.let { r ->
                        scope.launch {
                            if (cloud?.createBlockedTime(isoOf(r.first), isoOf(r.last)) == null) actionError = "Couldn't block that time."
                        }
                    }
                    null -> {}
                }
            },
        )
    }
    pendingBlockRemove?.let { b ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { pendingBlockRemove = null },
            containerColor = p.bgElevated,
            title = { Text("Remove blocked time?", color = p.textPrimary, style = AppFont.md) },
            text = { Text("People can book this time again.", color = p.textSecondary, style = AppFont.sm) },
            confirmButton = {
                Text("Remove", color = p.accentDanger, style = AppFont.md, modifier = Modifier.padding(Space.s2).noRippleClickable {
                    pendingBlockRemove = null
                    scope.launch { if (cloud?.deleteBlockedTime(b.id) != true) actionError = "Couldn't remove the blocked time." }
                })
            },
            dismissButton = { Text("Cancel", color = p.accentViolet, style = AppFont.md, modifier = Modifier.padding(Space.s2).noRippleClickable { pendingBlockRemove = null }) },
        )
    }
    actionError?.let { err ->
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { actionError = null }, containerColor = p.bgElevated,
            title = { Text("Couldn't update", color = p.textPrimary, style = AppFont.md) },
            text = { Text(err, color = p.textSecondary, style = AppFont.sm) },
            confirmButton = { Text("OK", color = p.accentViolet, style = AppFont.md, modifier = Modifier.padding(Space.s2).noRippleClickable { actionError = null }) },
        )
    }

    detail?.let { ev ->
        EventDetailSheet(engine, ev,
            onDismiss = { detail = null },
            onEdit = { detail = null; editing = ev },
            onDeleted = { detail = null },
            cloud = cloud.takeIf { zonesOn })
    }
    if (cloud != null && (zoneCreating || zoneEditing != null)) {
        ZoneSheet(cloud, zoneEditing,
            initialDay = if (tab == "Upcoming") chartDay ?: Date() else selectedDay,
            onDismiss = { zoneCreating = false; zoneEditing = null; createRange = null },
            initialRange = if (zoneEditing == null) createRange else null)
    }
    if (creating || editing != null) {
        // New events open on the day in view, like Google Calendar and Outlook.
        EventSheet(engine, editing, seed = draftSeed, inboxAccountKey = inboxAccountKey,
            initialDay = if (tab == "Upcoming") chartDay ?: Date() else selectedDay,
            onDismiss = { creating = false; editing = null; draftSeed = null; createRange = null; onSeedConsumed() },
            initialRange = if (editing == null) createRange else null)
    }
}

/** The channel order, for per-account event colours deep in the agenda/month rows. */
private val LocalChannelOrder = androidx.compose.runtime.compositionLocalOf { emptyList<String>() }

@Composable
private fun AgendaList(
    engine: EngineModel,
    events: List<CalendarEvent>,
    onTap: (CalendarEvent) -> Unit,
    onEdit: (CalendarEvent) -> Unit = {},
    chartEvents: List<CalendarEvent> = emptyList(),
    channelOrder: List<String> = emptyList(),
    chartDay: Date? = null,
    onSelectDay: (Date) -> Unit = {},
    zones: List<CloudZone> = emptyList(),
    categoryOf: (CloudZone) -> CloudZoneCategory? = { null },
    onOpenZone: (CloudZone) -> Unit = {},
) {
    val p = theme
    // Zones still running or ahead; each groups under the day it starts.
    val today = startOfDay(Date())
    val upcomingZones = zones.filter { it.endMs > today.time }
    if (events.isEmpty() && upcomingZones.isEmpty()) {
        Box(Modifier.fillMaxSize().padding(bottom = 80.dp), contentAlignment = Alignment.Center) {
            EmptyState("calendar", "No upcoming events", "Events from your connected calendars show up here")
        }
        return
    }
    // Tapping a chart bar filters the list to that day (iOS selectedChartDay), showing the
    // full day incl. already-ended events (faded). The default agenda keeps today's ended
    // events too, faded — as Google Calendar and Outlook do; hiding them made an event saved
    // for earlier today vanish as if the save had gone nowhere.
    // A tapped chart day filters the ±30-day chart set (past days included); the plain
    // list is today onward (iOS filters `chartEvents`).
    val listed = chartDay?.let { d -> chartEvents.filter { it.dayKey == startOfDay(d) } } ?: events
    val zonesByDay = upcomingZones.groupBy { startOfDay(Date(it.startMs)) }
        .filterKeys { d -> chartDay == null || d == startOfDay(chartDay) }
    val eventsByDay = listed.groupBy { it.dayKey }
    val grouped = (eventsByDay.keys + zonesByDay.keys).toSortedSet()
        .associateWith { d -> dayEntries(eventsByDay[d].orEmpty(), zonesByDay[d].orEmpty()) }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = Space.s4, vertical = Space.s2),
        verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        item {
            UpcomingLoadChart(chartEvents, channelOrder, chartDay, onSelectDay)
        }
        if (grouped.isEmpty()) item {
            Text("Nothing on this day", color = p.textTertiary, style = AppFont.sm,
                modifier = Modifier.fillMaxWidth().padding(vertical = Space.s6), textAlign = TextAlign.Center)
        }
        grouped.forEach { (day, dayEvents) ->
            item {
                Text(DayHeader.label(day), color = p.textSecondary, style = AppFont.ui(15, FontWeight.SemiBold),
                    modifier = Modifier.padding(top = Space.s3, bottom = Space.s1))
            }
            items(dayEvents.size) { i ->
                EntryRow(engine, dayEvents[i], onTap, onEdit, categoryOf, onOpenZone)
            }
        }
        item { Spacer(Modifier.height(90.dp)) }
    }
}

/** One agenda entry: an event row, or a zone block wrapping the events inside it. */
@Composable
private fun EntryRow(
    engine: EngineModel, entry: DayEntry,
    onTap: (CalendarEvent) -> Unit, onEdit: (CalendarEvent) -> Unit,
    categoryOf: (CloudZone) -> CloudZoneCategory?, onOpenZone: (CloudZone) -> Unit,
) {
    when (entry) {
        is EventEntry -> EventRow(engine, entry.event, onOpen = { onTap(entry.event) }, onEdit = { onEdit(entry.event) })
        is ZoneEntry -> ZoneBlock(entry.zone, categoryOf(entry.zone), onOpen = { onOpenZone(entry.zone) }) {
            entry.events.forEach { e -> EventRow(engine, e, onOpen = { onTap(e) }, onEdit = { onEdit(e) }) }
        }
    }
}

@Composable
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun EventRow(engine: EngineModel, event: CalendarEvent, onOpen: () -> Unit, onEdit: () -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    val density = androidx.compose.ui.platform.LocalDensity.current
    val color = event.calendarColorHex?.let { colorHex(it.removePrefix("#")) } ?: ChannelColor.base(event.accountKey)
    // Someone else's meeting: RSVP, no Edit (iOS engine.isInvite). Your own event
    // has an organizer too — you.
    val isInvite = remember(event) { engine.isInvite(event) }
    var menu by remember { mutableStateOf(false) }
    var rsvpSub by remember(menu) { mutableStateOf(false) }
    var rsvpFailed by remember { mutableStateOf(false) }
    if (rsvpFailed) androidx.compose.material3.AlertDialog(
        onDismissRequest = { rsvpFailed = false }, containerColor = p.bgElevated,
        title = { Text("Couldn't update event", color = p.textPrimary, style = AppFont.md) },
        text = { Text("Couldn't send your response. Try again.", color = p.textSecondary, style = AppFont.sm) },
        confirmButton = { Text("OK", color = p.accentViolet, style = AppFont.md, modifier = Modifier.padding(Space.s2).noRippleClickable { rsvpFailed = false }) },
    )
    var confirmDelete by remember { mutableStateOf(false) }
    var pressAt by remember { mutableStateOf(androidx.compose.ui.geometry.Offset.Zero) }
    Box {
        val g = p.groove
        val ink = g?.eventInk(event.isPast)
        val order = LocalChannelOrder.current
        Row(
            // Groovebox: the event is a solid pastel block with dark ink; an ended one
            // takes the muted fill instead of a fade.
            (if (g != null) Modifier.padding(horizontal = 4.dp).clip(RoundedCornerShape(Radius.lg))
                .background(g.eventFill(event.calendarColorHex, event.accountKey, order, event.isPast))
                else Modifier.insetCard(radius = 14))
                // Ended events read faded in the tapped-day view (iOS .opacity(isPast)).
                .alpha(if (event.isPast && g == null) 0.4f else 1f)
                // Tap opens; long-press opens the context menu at the touch point (iOS).
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = { onOpen() },
                        onLongPress = { at -> pressAt = at; menu = true },
                    )
                }
                .padding(Space.s3),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (g == null) {
                Box(Modifier.width(4.dp).height(40.dp).clip(RoundedCornerShape(Radius.full)).background(color))
                Spacer(Modifier.width(Space.s3))
            }
            Column(Modifier.weight(1f)) {
                Text(event.title, color = ink ?: p.textPrimary, style = AppFont.md, maxLines = 1)
                Text(listOfNotNull(event.rangeLabel, event.location).joinToString(" · "), color = ink?.copy(alpha = 0.7f) ?: p.textTertiary, style = AppFont.xs, maxLines = 1)
            }
        }
        com.inbox2.app.ui.components.GlassDropdownMenu(
            expanded = menu, onDismissRequest = { menu = false },
            offset = with(density) { androidx.compose.ui.unit.DpOffset(pressAt.x.toDp(), pressAt.y.toDp()) },
        ) {
            if (!rsvpSub) {
                EventMenuRow("Open", "calendar") { menu = false; onOpen() }
                if (isInvite) {
                    androidx.compose.material3.HorizontalDivider()
                    EventMenuRow("RSVP", "checkmark.circle.fill", trailing = true) { rsvpSub = true }
                }
                if (event.calendarWritable) {
                    androidx.compose.material3.HorizontalDivider()
                    if (!isInvite) EventMenuRow("Edit", "square.and.pencil", p.accentViolet) { menu = false; onEdit() }
                    EventMenuRow("Delete", "trash", p.accentDanger) { menu = false; confirmDelete = true }
                }
            } else {
                EventMenuBackRow("RSVP") { rsvpSub = false }
                androidx.compose.material3.HorizontalDivider()
                EventMenuRow("Going", "checkmark.circle.fill", p.accentSuccess) { menu = false; scope.launch { if (!engine.respondToEvent(event.accountKey, event.id, "accepted")) rsvpFailed = true } }
                EventMenuRow("Maybe", "questionmark.circle.fill", p.accentAmber) { menu = false; scope.launch { if (!engine.respondToEvent(event.accountKey, event.id, "tentative")) rsvpFailed = true } }
                EventMenuRow("Decline", "xmark.circle.fill", p.accentDanger) { menu = false; scope.launch { if (!engine.respondToEvent(event.accountKey, event.id, "declined")) rsvpFailed = true } }
            }
        }
    }
    if (confirmDelete) DeleteEventDialog(engine, event, onDismiss = { confirmDelete = false })
}

@Composable
private fun EventMenuRow(label: String, icon: String, tint: androidx.compose.ui.graphics.Color = theme.textPrimary, trailing: Boolean = false, onClick: () -> Unit) {
    androidx.compose.material3.DropdownMenuItem(
        text = { Text(label, color = theme.textPrimary, style = AppFont.sm) },
        leadingIcon = { Icon(SfIcon.vector(icon), null, tint = tint, modifier = Modifier.size(18.dp)) },
        trailingIcon = if (trailing) { { Icon(SfIcon.vector("chevron.right"), null, tint = theme.textTertiary, modifier = Modifier.size(16.dp)) } } else null,
        onClick = onClick,
    )
}

@Composable
private fun EventMenuBackRow(label: String, onBack: () -> Unit) {
    androidx.compose.material3.DropdownMenuItem(
        text = { Text(label, color = theme.textPrimary, style = AppFont.ui(14, FontWeight.SemiBold)) },
        leadingIcon = { Icon(SfIcon.vector("chevron.left"), null, tint = theme.textSecondary, modifier = Modifier.size(16.dp)) },
        onClick = onBack,
    )
}

@Composable
private fun MonthGrid(
    engine: EngineModel,
    anchor: Date, selectedDay: Date, events: List<CalendarEvent>,
    onPrev: () -> Unit, onNext: () -> Unit, onToday: () -> Unit,
    onPickDay: (Date) -> Unit, onTapEvent: (CalendarEvent) -> Unit,
    onEditEvent: (CalendarEvent) -> Unit = {},
    zones: List<CloudZone> = emptyList(),
    categoryOf: (CloudZone) -> CloudZoneCategory? = { null },
    onOpenZone: (CloudZone) -> Unit = {},
) {
    val p = theme
    val cal = Calendar.getInstance()
    // Bucket each event onto every day it spans (multi-day events show on all days).
    val byDay = remember(events) {
        val map = HashMap<Date, MutableList<CalendarEvent>>()
        events.forEach { e ->
            val s = startOfDay(e.start ?: return@forEach)
            val end = startOfDay(e.end ?: e.start ?: return@forEach)
            var d = s
            var guard = 0
            while (!d.after(end) && guard < 90) {
                map.getOrPut(d) { mutableListOf() }.add(e)
                d = Calendar.getInstance().apply { time = d; add(Calendar.DAY_OF_YEAR, 1) }.time
                guard++
            }
        }
        map
    }
    // Zones onto every day they touch (an overnight zone underlines both days).
    val zonesByDay = remember(zones) {
        val map = HashMap<Date, MutableList<CloudZone>>()
        zones.forEach { z ->
            var d = startOfDay(Date(z.startMs))
            val last = startOfDay(Date(maxOf(z.startMs, z.endMs - 1)))
            var guard = 0
            while (!d.after(last) && guard++ < 90) { map.getOrPut(d) { mutableListOf() }.add(z); d = addDays(d, 1) }
        }
        map
    }

    Column(Modifier.fillMaxSize()) {
        // Month nav
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4, vertical = Space.s2), verticalAlignment = Alignment.CenterVertically) {
            Icon(SfIcon.vector("chevron.left"), "Prev", tint = p.textSecondary,
                modifier = Modifier.size(22.dp).noRippleClickable { onPrev() })
            Text(SimpleDateFormat("MMMM yyyy", Locale.getDefault()).format(anchor), color = p.textPrimary,
                style = AppFont.title3, modifier = Modifier.weight(1f).padding(horizontal = Space.s3))
            Text("Today", color = p.accentViolet, style = AppFont.xs,
                modifier = Modifier.noRippleClickable { onToday() })
            Spacer(Modifier.width(Space.s3))
            Icon(SfIcon.vector("chevron.right"), "Next", tint = p.textSecondary,
                modifier = Modifier.size(22.dp).noRippleClickable { onNext() })
        }
        // Weekday row (locale first day)
        val firstDow = cal.firstDayOfWeek
        val weekdays = (0..6).map { i ->
            val c = Calendar.getInstance(); c.set(Calendar.DAY_OF_WEEK, ((firstDow - 1 + i) % 7) + 1)
            SimpleDateFormat("EEE", Locale.getDefault()).format(c.time).take(2)
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4)) {
            weekdays.forEach { Text(it, color = p.textTertiary, style = AppFont.xs2, textAlign = TextAlign.Center, modifier = Modifier.weight(1f)) }
        }
        // Grid
        val cells = monthCells(anchor)
        Column(Modifier.padding(horizontal = Space.s4, vertical = Space.s1)) {
            cells.chunked(7).forEach { week ->
                Row(Modifier.fillMaxWidth()) {
                    week.forEach { day ->
                        val key = day?.let { startOfDay(it) }
                        DayCell(day, anchor, selectedDay, byDay[key].orEmpty(),
                            zoneColors = zonesByDay[key].orEmpty().map { zoneColor(categoryOf(it)) },
                            modifier = Modifier.weight(1f)) { day?.let(onPickDay) }
                    }
                }
            }
        }
        // Day detail
        // The day's zones are the ones starting that day (an overnight zone lists once).
        val dayEvents = dayEntries(byDay[startOfDay(selectedDay)].orEmpty(),
            zones.filter { startOfDay(Date(it.startMs)) == startOfDay(selectedDay) })
        Text(DayHeader.label(selectedDay), color = p.textSecondary, style = AppFont.ui(15, FontWeight.SemiBold),
            modifier = Modifier.padding(horizontal = Space.s4, vertical = Space.s2))
        if (dayEvents.isEmpty()) {
            Text("No events", color = p.textTertiary, style = AppFont.sm, modifier = Modifier.padding(horizontal = Space.s4))
        } else {
            LazyColumn(contentPadding = PaddingValues(horizontal = Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                items(dayEvents.size) { i ->
                    EntryRow(engine, dayEvents[i], onTapEvent, onEditEvent, categoryOf, onOpenZone)
                }
                item { Spacer(Modifier.height(90.dp)) }
            }
        }
    }
}

@Composable
private fun DayCell(day: Date?, anchor: Date, selected: Date, dayEvents: List<CalendarEvent>, modifier: Modifier,
                    zoneColors: List<Color> = emptyList(), onClick: () -> Unit) {
    val p = theme
    if (day == null) { Box(modifier.height(44.dp)); return }
    val isSelected = startOfDay(day) == startOfDay(selected)
    val isToday = startOfDay(day) == startOfDay(Date())
    val inMonth = Calendar.getInstance().apply { time = day }.get(Calendar.MONTH) ==
        Calendar.getInstance().apply { time = anchor }.get(Calendar.MONTH)
    val g = p.groove
    val numColor = when {
        isSelected && g != null -> g.creamInk           // on the cream keycap
        isToday -> g?.led ?: p.accentViolet            // Groovebox: today is the LED
        !inMonth -> p.textTertiary.copy(alpha = 0.5f)   // dimmed adjacent-month day
        else -> p.textPrimary
    }
    Box(
        modifier.height(44.dp).padding(2.dp)
            .then(if (isSelected && g != null) Modifier.creamKeycap(g) else Modifier)
            .clip(CircleShape)
            .then(if (isSelected && g == null) Modifier.background(p.accentViolet.copy(alpha = 0.25f)) else Modifier)
            .noRippleClickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(SimpleDateFormat("d", Locale.getDefault()).format(day), color = numColor,
                style = AppFont.ui(14, if (isToday) FontWeight.Bold else FontWeight.Normal))
            // Up to 3 per-channel colored dots (iOS dayCell).
            if (dayEvents.isNotEmpty()) Row(Modifier.padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                dayEvents.take(3).forEach { e ->
                    val c = e.calendarColorHex?.let { colorHex(it.removePrefix("#")) } ?: ChannelColor.base(e.accountKey)
                    Box(Modifier.size(5.dp).clip(CircleShape)
                        .background(g?.eventFill(e.calendarColorHex, e.accountKey, LocalChannelOrder.current, false) ?: c))
                }
            }
            // One thin underline per zone that day (up to 3), in its category colour.
            if (zoneColors.isNotEmpty()) Row(Modifier.padding(top = 2.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                zoneColors.take(3).forEach { c -> Box(Modifier.width(8.dp).height(2.dp).clip(RoundedCornerShape(Radius.full)).background(c)) }
            }
        }
    }
}

/** One day's stacked load: channel segments (stable by first appearance) + total. */
private data class DayLoad(val day: Date, val segments: List<Pair<String, Int>>, val total: Int)

/**
 * Horizontally-scrollable load gauge spanning ±30 days (iOS UpcomingLoadChart):
 * one stacked bar per day, each segment coloured by its channel, opening on
 * today. Bar colours line up with the agenda strips below; tapping a bar
 * filters the agenda to that day.
 */
@Composable
private fun UpcomingLoadChart(
    events: List<CalendarEvent>,
    channelOrder: List<String>,
    selectedDay: Date?,
    onSelect: (Date) -> Unit,
) {
    val p = theme
    val today = startOfDay(Date())
    val loads = remember(events) {
        val counts = HashMap<Date, LinkedHashMap<String, Int>>()
        for (ev in events) {
            val m = counts.getOrPut(ev.dayKey) { LinkedHashMap() }
            m[ev.accountKey] = (m[ev.accountKey] ?: 0) + 1
        }
        (-30..30).map { off ->
            val day = addDays(today, off)
            val m = counts[day] ?: LinkedHashMap()
            DayLoad(day, m.entries.map { it.key to it.value }, m.values.sum())
        }
    }
    val maxTotal = maxOf(loads.maxOfOrNull { it.total } ?: 0, 1)
    val upcoming = loads.filter { !it.day.before(today) }.sumOf { it.total }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    // Open on today, one column of past peeking on the left (iOS anchor x=0.12).
    LaunchedEffect(Unit) { listState.scrollToItem(29) }

    Column(Modifier.padding(bottom = Space.s2)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("MEETING LOAD", color = p.textTertiary, style = AppFont.xs3.copy(letterSpacing = 0.7.sp))
            Spacer(Modifier.width(Space.s2))
            Text("Today", color = p.accentViolet, style = AppFont.xs3,
                modifier = Modifier.noRippleClickable { onSelect(today); scope.launch { listState.animateScrollToItem(29) } })
            Spacer(Modifier.weight(1f))
            Text(buildAnnotatedString {
                withStyle(SpanStyle(color = p.textSecondary)) { append("$upcoming upcoming") }
                withStyle(SpanStyle(color = p.textTertiary)) { append(" / 30d") }
            }, style = AppFont.xs3)
        }
        Spacer(Modifier.height(Space.s2))
        LazyRow(
            state = listState,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            items(loads.size) { i -> LoadColumn(loads[i], maxTotal, today, selectedDay, channelOrder, onSelect) }
        }
    }
}

@Composable
private fun LoadColumn(
    load: DayLoad,
    maxTotal: Int,
    today: Date,
    selectedDay: Date?,
    channelOrder: List<String>,
    onSelect: (Date) -> Unit,
) {
    val p = theme
    val barWidth = 18.dp
    val maxBarHeight = 54.dp
    val isToday = load.day == today
    val isPast = load.day.before(today)
    val isSelected = selectedDay != null && startOfDay(selectedDay) == load.day
    Column(
        Modifier.width(30.dp).noRippleClickable { onSelect(load.day) },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(
            if (load.total > 0) "${load.total}" else " ",
            color = if (load.total > 0) (if (isPast) p.textTertiary else p.textSecondary) else Color.Transparent,
            style = AppFont.xs3,
        )
        Box(
            Modifier
                .then(if (isSelected) Modifier.border(1.5.dp, p.ringGradient, RoundedCornerShape(Radius.lg)) else Modifier)
                .padding(2.dp),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Box(
                Modifier.width(barWidth).height(maxBarHeight)
                    .clip(RoundedCornerShape(Radius.md))
                    .background(if (p.groove != null) p.bgInput else if (isToday) p.accentViolet.copy(alpha = 0.12f) else p.borderDefault),
            )
            if (load.total > 0) {
                val height = maxOf(8f, load.total.toFloat() / maxTotal * 54f)
                val gaps = maxOf(0, load.segments.size - 1) * 1.5f
                val inner = maxOf(height - gaps, load.segments.size * 3f)
                Column(
                    Modifier.width(barWidth).clip(RoundedCornerShape(Radius.md))
                        .alpha(if (isPast && p.groove == null) 0.5f else 1f),
                    verticalArrangement = Arrangement.spacedBy(1.5.dp),
                ) {
                    load.segments.forEach { (key, count) ->
                        Box(
                            Modifier.fillMaxWidth()
                                .height(maxOf(3f, inner * count / load.total).dp)
                                .background(p.groove?.let { SolidColor(it.eventFill(null, key, channelOrder, isPast)) } ?: ChannelColor.gradient(key, channelOrder)),
                        )
                    }
                }
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                weekdayLetter(load.day),
                color = if (isToday) p.groove?.led ?: p.accentViolet else if (isPast) p.textTertiary.copy(alpha = if (p.groove != null) 1f else 0.6f) else p.textTertiary,
                style = AppFont.xs3,
            )
            Text(
                "${Calendar.getInstance().apply { time = load.day }.get(Calendar.DAY_OF_MONTH)}",
                color = if (isToday) p.groove?.led ?: p.accentViolet else if (isPast) p.textTertiary.copy(alpha = if (p.groove != null) 1f else 0.6f) else p.textSecondary,
                style = AppFont.ui(12, if (isToday || isSelected) FontWeight.Bold else FontWeight.Normal),
            )
        }
    }
}

private fun weekdayLetter(day: Date): String =
    SimpleDateFormat("EEEEE", Locale.getDefault()).format(day)

// ── date helpers ──────────────────────────────────────────────────────────────
private fun addDays(d: Date, n: Int): Date = Calendar.getInstance().apply { time = d; add(Calendar.DAY_OF_MONTH, n) }.time
private fun startOfDay(d: Date): Date = Calendar.getInstance().apply {
    time = d; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.time
private fun startOfMonth(d: Date): Date = Calendar.getInstance().apply {
    time = startOfDay(d); set(Calendar.DAY_OF_MONTH, 1)
}.time
private fun addMonths(d: Date, n: Int): Date = Calendar.getInstance().apply { time = d; add(Calendar.MONTH, n) }.time
private fun isoOffset(d: Date): String =
    DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(Instant.ofEpochMilli(d.time).atZone(ZoneId.systemDefault()))

/** A fixed 6×7 grid starting on the locale's first weekday, spilling into the adjacent
 *  months (dimmed by the cell) — iOS month grid. */
private fun monthCells(anchor: Date): List<Date?> {
    val cal = Calendar.getInstance().apply { time = startOfMonth(anchor) }
    val firstDow = cal.firstDayOfWeek
    val lead = ((cal.get(Calendar.DAY_OF_WEEK) - firstDow) + 7) % 7
    val start = Calendar.getInstance().apply { time = startOfMonth(anchor); add(Calendar.DAY_OF_YEAR, -lead) }
    return (0 until 42).map { i ->
        Calendar.getInstance().apply { time = start.time; add(Calendar.DAY_OF_YEAR, i) }.time
    }
}
