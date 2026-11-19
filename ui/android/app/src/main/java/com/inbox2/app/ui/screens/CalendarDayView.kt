package com.inbox2.app.ui.screens

import com.inbox2.app.model.DateFmt
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.inbox2.app.cloud.CloudBlockedTime
import com.inbox2.app.cloud.CloudZone
import com.inbox2.app.cloud.CloudZoneCategory
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.CalendarEvent
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.ChannelColor
import com.inbox2.app.ui.components.pastelChip
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.SfIcon
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
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Calendar "Day" mode (iOS CalendarDayView): a 24-hour timeline. Zones are striped bands
 * behind the events, overlapping events sit side by side, and a long-press + vertical
 * drag on empty grid picks a 15-minute-snapped range that `onCreate` turns into a new
 * event, zone or blocked window (grey hatched, tap to remove). Swiping sideways pages days.
 */
@Composable
fun CalendarDayView(
    engine: EngineModel,
    day: Date,
    onDayChange: (Date) -> Unit,
    channelOrder: List<String>,
    zones: List<CloudZone>,
    categoryOf: (CloudZone) -> CloudZoneCategory?,
    blocks: List<CloudBlockedTime>,
    /** The range the create chooser is asking about — kept drawn while it's up. */
    highlight: LongRange?,
    onSelect: (CalendarEvent) -> Unit,
    onEditZone: (CloudZone) -> Unit,
    onSelectBlock: (CloudBlockedTime) -> Unit,
    onCreate: (LongRange) -> Unit,
) {
    val p = theme
    val dataVersion by engine.dataVersion.collectAsState()
    val cal = Calendar.getInstance()
    val dayStart = remember(day) { dayStartMs(day.time) }
    val dayEnd = remember(dayStart) { Calendar.getInstance().apply { timeInMillis = dayStart; add(Calendar.DAY_OF_MONTH, 1) }.timeInMillis }
    val hourHeight = 56.dp
    val gutter = 52.dp
    val gridHeight = hourHeight * 24
    val density = LocalDensity.current
    val haptics = LocalHapticFeedback.current

    var events by remember { mutableStateOf<List<CalendarEvent>>(emptyList()) }
    LaunchedEffect(dayStart, dataVersion) {
        val all = withContext(Dispatchers.IO) { engine.store.eventsBetween(isoOf(dayStart), isoOf(dayEnd)) }
        // The query's `end >= from` also returns what ends exactly at midnight.
        events = all.filter { ev ->
            val s = ev.start?.time ?: return@filter false
            s < dayEnd && ((ev.end?.time ?: s) > dayStart || s >= dayStart)
        }
    }

    // ── Time ↔ position (wall clock, so DST days still fit 24 rows) ──
    fun minutes(ms: Long): Float {
        if (ms <= dayStart) return 0f
        if (ms >= dayEnd) return 1440f
        val c = Calendar.getInstance().apply { timeInMillis = ms }
        return (c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE)).toFloat()
    }
    fun y(ms: Long): Dp = hourHeight * (minutes(ms) / 60f)
    fun dateAt(minute: Int): Long = if (minute >= 1440) dayEnd
        else Calendar.getInstance().apply { timeInMillis = dayStart; set(Calendar.HOUR_OF_DAY, minute / 60); set(Calendar.MINUTE, minute % 60) }.timeInMillis
    fun slot(yPx: Float): Int = min(1425, max(0, (yPx / with(density) { hourHeight.toPx() } * 4).toInt() * 15))

    var dragAnchor by remember { mutableStateOf<Int?>(null) }
    var dragCurrent by remember { mutableStateOf<Int?>(null) }
    fun rangeOf(a: Int?, c: Int?): LongRange? = if (a == null || c == null) null else dateAt(min(a, c))..dateAt(max(a, c) + 15)
    val dragRange: LongRange? = rangeOf(dragAnchor, dragCurrent)
    // The gesture block is remembered per day; read the latest callback, not the one
    // captured when it was installed.
    val onCreateNow by androidx.compose.runtime.rememberUpdatedState(onCreate)

    fun isAllDay(e: CalendarEvent) = e.allDay || ((e.start?.time ?: Long.MAX_VALUE) <= dayStart && (e.end?.time ?: Long.MIN_VALUE) >= dayEnd)
    val allDayEvents = events.filter(::isAllDay)
    val timedEvents = events.filter { !isAllDay(it) && it.start != null }
    val dayBlocks = blocks.filter { (it.start?.time ?: 0L) < dayEnd && (it.end?.time ?: 0L) > dayStart }
    val dayZones = zones.filter { it.startMs < dayEnd && it.endMs > dayStart }
    val isToday = dayStartMs(System.currentTimeMillis()) == dayStart

    fun shift(delta: Int) = onDayChange(Calendar.getInstance().apply { timeInMillis = dayStart; add(Calendar.DAY_OF_MONTH, delta) }.time)

    val scroll = rememberScrollState()
    LaunchedEffect(dayStart) {
        val h = if (isToday) max(0, Calendar.getInstance().get(Calendar.HOUR_OF_DAY) - 1) else 8
        scroll.scrollTo(with(density) { (hourHeight * h).roundToPx() })
    }

    // Swipe left/right pages days; the vertical scroll is untouched.
    var swipeDx by remember { mutableStateOf(0f) }
    Column(
        Modifier.fillMaxSize().draggable(
            orientation = Orientation.Horizontal,
            state = rememberDraggableState { swipeDx += it },
            onDragStopped = { if (dragAnchor == null && abs(swipeDx) > with(density) { 80.dp.toPx() }) shift(if (swipeDx < 0) 1 else -1); swipeDx = 0f },
        ),
    ) {
        // Header: day label, Today, previous/next.
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s4, vertical = Space.s1), verticalAlignment = Alignment.CenterVertically) {
            val label = dayLabel(dayStart)
            val full = DateFmt.dayHeader(Date(dayStart))
            Column {
                Text(label, color = p.textPrimary, style = AppFont.title3)
                if (label != full && !label.startsWith(full)) Text(full, color = p.textTertiary, style = AppFont.xs2)
            }
            Spacer(Modifier.weight(1f))
            if (!isToday) Text("Today", color = p.accentViolet, style = AppFont.ui(13, FontWeight.SemiBold),
                modifier = Modifier.padding(end = Space.s2).noRippleClickable { onDayChange(Date(dayStartMs(System.currentTimeMillis()))) })
            Icon(SfIcon.vector("chevron.left"), "Previous day", tint = p.accentViolet, modifier = Modifier.size(36.dp).padding(8.dp).noRippleClickable { shift(-1) })
            Icon(SfIcon.vector("chevron.right"), "Next day", tint = p.accentViolet, modifier = Modifier.size(36.dp).padding(8.dp).noRippleClickable { shift(1) })
        }
        if (allDayEvents.isNotEmpty()) Row(Modifier.fillMaxWidth().padding(vertical = Space.s1), verticalAlignment = Alignment.CenterVertically) {
            Text("all-day", color = p.textTertiary, style = AppFont.xs3, modifier = Modifier.width(gutter - Space.s2).padding(end = Space.s2), textAlign = androidx.compose.ui.text.style.TextAlign.End)
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.s1)) {
                allDayEvents.forEach { ev ->
                    val base = ChannelColor.base(ev.accountKey, channelOrder)
                    val g = p.groove
                    // Groovebox: a solid pastel chip with dark ink.
                    Text(ev.title, color = g?.eventInk(ev.isPast) ?: p.textPrimary, style = AppFont.ui(12, FontWeight.SemiBold), maxLines = 1,
                        modifier = (if (g != null) Modifier.pastelChip(g.eventFill(ev.calendarColorHex, ev.accountKey, channelOrder, ev.isPast), g, Radius.md) else Modifier)
                            .clip(RoundedCornerShape(Radius.md))
                            .then(if (g == null) Modifier.background(base.copy(alpha = 0.22f)) else Modifier)
                            .noRippleClickable { onSelect(ev) }.padding(horizontal = Space.s2, vertical = 4.dp)
                            .then(if (g != null) Modifier.padding(bottom = 2.dp) else Modifier))
                }
            }
        }

        BoxWithConstraints(Modifier.fillMaxSize().verticalScroll(scroll, enabled = dragAnchor == null)) {
            val width = maxWidth
            val contentW = (width - gutter - Space.s2).coerceAtLeast(0.dp)
            val rects = frames(timedEvents, dayBlocks, contentW, gutter, ::y)

            Box(Modifier.fillMaxWidth().height(gridHeight + Space.s2 * 2).padding(vertical = Space.s2)) {
                // Hour labels + hour lines with dotted half-hours (iOS gridLines).
                Column {
                    repeat(24) { h ->
                        Text(String.format(Locale.US, "%02d:00", h), color = p.textTertiary, style = AppFont.xs3,
                            modifier = Modifier.width(gutter - Space.s2).height(hourHeight).offset(y = (-6).dp),
                            textAlign = androidx.compose.ui.text.style.TextAlign.End)
                    }
                }
                Box(Modifier.fillMaxWidth().height(gridHeight).drawBehind {
                    val g = gutter.toPx(); val hh = hourHeight.toPx()
                    val line = p.groove?.timeGrid ?: p.borderDefault   // Groovebox: violet guide lines
                    for (h in 0..24) {
                        val yy = h * hh
                        drawLine(line, Offset(g, yy), Offset(size.width, yy), 0.5.dp.toPx())
                        if (h < 24) drawLine(line.copy(alpha = line.alpha * 0.6f), Offset(g, yy + hh / 2), Offset(size.width, yy + hh / 2), 0.5.dp.toPx(),
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 3.dp.toPx())))
                    }
                })

                // Empty grid: long-press then drag selects a range.
                Box(
                    Modifier.offset(x = gutter).width(contentW).height(gridHeight).pointerInput(dayStart) {
                        detectDragGesturesAfterLongPress(
                            onDragStart = { pos -> dragAnchor = slot(pos.y); dragCurrent = dragAnchor; haptics.performHapticFeedback(HapticFeedbackType.LongPress) },
                            onDrag = { change, _ ->
                                val s = slot(change.position.y)
                                if (s != dragCurrent) { dragCurrent = s; haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove) }
                            },
                            onDragEnd = { rangeOf(dragAnchor, dragCurrent)?.let { onCreateNow(it) }; dragAnchor = null; dragCurrent = null },
                            onDragCancel = { dragAnchor = null; dragCurrent = null },
                        )
                    },
                )

                dayZones.forEach { z ->
                    val top = y(z.startMs)
                    DayZoneBand(z, categoryOf(z), height = (y(z.endMs) - top).coerceAtLeast(24.dp),
                        modifier = Modifier.offset(x = gutter, y = top).width(contentW)) { onEditZone(z) }
                }

                dayBlocks.forEach { b ->
                    val r = rects[b.id] ?: return@forEach
                    val past = (b.end?.time ?: 0L) < System.currentTimeMillis()
                    Column(
                        Modifier.offset(x = r.x, y = r.y).size(r.w, r.h).padding(1.dp).alpha(if (past) 0.55f else 1f)
                            .clip(RoundedCornerShape(Radius.md)).background(p.bgBase).zoneFill(p.textTertiary)
                            .border(1.dp, p.textTertiary.copy(alpha = 0.45f), RoundedCornerShape(Radius.md))
                            .noRippleClickable { onSelectBlock(b) }.padding(horizontal = 6.dp, vertical = 3.dp),
                    ) {
                        Text("Blocked", color = p.textSecondary, style = AppFont.ui(12, FontWeight.SemiBold), maxLines = 1)
                        if (r.h >= 34.dp) Text("${DateFmt.hm(b.start?.time ?: 0L)} – ${DateFmt.hm(b.end?.time ?: 0L)}", color = p.textTertiary, style = AppFont.xs3, maxLines = 1)
                    }
                }

                timedEvents.forEach { ev ->
                    val r = rects[ev.id] ?: return@forEach
                    val range = if (ev.endTimeLabel.isEmpty()) ev.startTimeLabel else "${ev.startTimeLabel} – ${ev.endTimeLabel}"
                    val g = p.groove
                    // Groovebox: a solid pastel block with dark ink, no channel stripe.
                    if (g != null) Column(
                        // Full-opacity block; an ended event takes the muted fill, never a fade.
                        Modifier.offset(x = r.x, y = r.y).size(r.w, r.h).padding(1.dp)
                            .clip(RoundedCornerShape(Radius.md))
                            .background(g.eventFill(ev.calendarColorHex, ev.accountKey, channelOrder, ev.isPast))
                            .noRippleClickable { onSelect(ev) }.padding(horizontal = 6.dp, vertical = 3.dp),
                    ) {
                        val ink = g.eventInk(ev.isPast)
                        Text(ev.title, color = ink, style = AppFont.ui(12, FontWeight.SemiBold), maxLines = if (r.h > 44.dp) 2 else 1)
                        if (r.h >= 34.dp) Text(range, color = ink.copy(alpha = if (ev.isPast) 1f else 0.7f), style = AppFont.xs3, maxLines = 1)
                    } else Row(
                        Modifier.offset(x = r.x, y = r.y).size(r.w, r.h).alpha(if (ev.isPast) 0.55f else 1f)
                            .clip(RoundedCornerShape(Radius.md)).background(p.bgBase)   // opaque base so zone stripes don't show through
                            .background(ChannelColor.base(ev.accountKey, channelOrder).copy(alpha = 0.22f))
                            .border(1.dp, p.bgBase, RoundedCornerShape(Radius.md))     // gap between side-by-side blocks
                            .noRippleClickable { onSelect(ev) },
                    ) {
                        Box(Modifier.width(3.dp).fillMaxSize().background(ChannelColor.gradient(ev.accountKey, channelOrder)))
                        Column(Modifier.padding(horizontal = 5.dp, vertical = 3.dp)) {
                            Text(ev.title, color = p.textPrimary, style = AppFont.ui(12, FontWeight.SemiBold), maxLines = if (r.h > 44.dp) 2 else 1)
                            if (r.h >= 34.dp) Text(range, color = p.textSecondary, style = AppFont.xs3, maxLines = 1)
                        }
                    }
                }

                if (isToday) {
                    val now = rememberNow(60_000)
                    val ny = y(now)
                    val nowColor = p.groove?.nowLine ?: p.accentDanger   // Groovebox: mustard
                    Box(Modifier.offset(x = gutter - 4.dp, y = ny - 0.75.dp).width(contentW + 4.dp).height(1.5.dp).background(nowColor))
                    Box(Modifier.offset(x = gutter - 8.dp, y = ny - 4.dp).size(8.dp).clip(CircleShape).background(nowColor))
                }

                (dragRange ?: highlight)?.let { r ->
                    if (r.first < dayEnd && r.last > dayStart) {
                        val top = y(r.first)
                        Box(
                            Modifier.offset(x = gutter, y = top).width(contentW).height((y(r.last) - top).coerceAtLeast(14.dp))
                                .clip(RoundedCornerShape(Radius.md)).background(p.accentViolet.copy(alpha = 0.2f))
                                .border(1.5.dp, p.accentViolet, RoundedCornerShape(Radius.md)),
                        ) {
                            Text("${DateFmt.hm(r.first)} – ${DateFmt.hm(r.last)}", color = p.accentViolet, style = AppFont.ui(12, FontWeight.SemiBold),
                                modifier = Modifier.padding(horizontal = 6.dp, vertical = 3.dp))
                        }
                    }
                }
            }
        }
    }
}

/** A zone behind the day grid: striped tint + outline over its span, label (category ·
 *  name, "N left" while active) at the top-left. Only the label takes touches, so the
 *  band stays a drag-to-create target. */
@Composable
private fun DayZoneBand(zone: CloudZone, cat: CloudZoneCategory?, height: Dp, modifier: Modifier, onTap: () -> Unit) {
    val p = theme
    val tone = zoneColor(cat)
    val label = zoneText(tone)
    val now = rememberNow(30_000)
    val active = zone.isActive(now)
    Box(
        modifier.height(height).alpha(if (zone.endMs < now) 0.5f else 1f)
            .clip(RoundedCornerShape(Radius.lg)).zoneFill(tone)
            .border(if (active) 1.5.dp else 1.dp, tone.copy(alpha = if (active) 0.85f else 0.45f), RoundedCornerShape(Radius.lg)),
    ) {
        val g = p.groove
        Row(
            // Groovebox: the label rides a solid pastel chip with dark ink.
            (if (g != null) Modifier.padding(4.dp).pastelChip(tone, g) else Modifier)
                .noRippleClickable(onClick = onTap).padding(horizontal = Space.s2, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            if (g == null) Box(Modifier.size(6.dp).clip(CircleShape).background(tone))
            Text((cat?.name ?: "Zone").uppercase(), color = g?.chipInk ?: label, style = AppFont.xs3, maxLines = 1)
            Text(zone.name, color = g?.chipInk ?: p.textPrimary, style = AppFont.ui(12, FontWeight.SemiBold), maxLines = 1)
            if (active) Text(leftLabel(zone.endMs), color = label, style = AppFont.ui(11, FontWeight.SemiBold),
                modifier = Modifier.clip(CircleShape).background(tone.copy(alpha = 0.22f)).padding(horizontal = 6.dp, vertical = 1.dp))
        }
    }
}

private class Frame(val x: Dp, val y: Dp, val w: Dp, val h: Dp)

/** Block frames: overlapping events (and blocked windows, which lay out like events)
 *  split the width into columns, one greedy column assignment per overlap cluster. */
private fun frames(events: List<CalendarEvent>, blocks: List<CloudBlockedTime>, contentW: Dp, gutter: Dp, y: (Long) -> Dp): Map<String, Frame> {
    class Item(val id: String, val lo: Float, val hi: Float, var col: Int = 0)
    val items = (events.map { Triple(it.id, it.start!!.time, it.end?.time ?: it.start!!.time) } +
        blocks.map { Triple(it.id, it.start?.time ?: 0L, it.end?.time ?: 0L) })
        .map { (id, s, e) -> val lo = y(s).value; Item(id, lo, max(y(e).value, lo + 22f)) }
        .sortedBy { it.lo }
    val out = HashMap<String, Frame>()
    var cluster = ArrayList<Item>(); val colEnds = ArrayList<Float>(); var clusterEnd = -1f
    fun flush() {
        val w = contentW / max(1, colEnds.size)
        cluster.forEach { out[it.id] = Frame(gutter + w * it.col, it.lo.dp, w, (it.hi - it.lo).dp) }
        cluster = ArrayList(); colEnds.clear()
    }
    for (it in items) {
        if (it.lo >= clusterEnd) flush()
        val i = colEnds.indexOfFirst { end -> end <= it.lo }
        if (i >= 0) { colEnds[i] = it.hi; it.col = i } else { colEnds.add(it.hi); it.col = colEnds.size - 1 }
        cluster.add(it); clusterEnd = max(clusterEnd, it.hi)
    }
    flush()
    return out
}

/** What the calendar's create chooser offers (iOS CreateKind). */
enum class CreateKind(val title: String, val hint: String, val icon: String) {
    EVENT("New event", "Invite people to it", "calendar.badge.plus"),
    ZONE("New zone", "Focus time, still bookable", "scope"),
    BLOCK("Block time", "Shows you as busy", "nosign"),
}

/** Compact create chooser: one row per choice with a hint, the selected range on top
 *  (iOS CreateChoiceSheet — a plain menu can't show the hint). */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun CreateChoiceSheet(range: LongRange?, kinds: List<CreateKind>, onPick: (CreateKind?) -> Unit) {
    val p = theme
    ModalBottomSheet(onDismissRequest = { onPick(null) }, containerColor = p.bgPanel) {
        Column(Modifier.padding(bottom = Space.s6)) {
            range?.let {
                Text("${chooserDay.format(Date(it.first))} · ${DateFmt.hm(it.first)}–${DateFmt.hm(it.last)}", color = p.textSecondary, style = AppFont.sm,
                    modifier = Modifier.padding(horizontal = Space.s5).padding(bottom = Space.s2))
            }
            kinds.forEach { kind ->
                Row(
                    Modifier.fillMaxWidth().noRippleClickable { onPick(kind) }.padding(horizontal = Space.s5, vertical = Space.s3),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s4),
                ) {
                    Icon(SfIcon.vector(kind.icon), null, tint = p.accentViolet, modifier = Modifier.size(26.dp))
                    Column {
                        Text(kind.title, color = p.textPrimary, style = AppFont.body)
                        Text(kind.hint, color = p.textTertiary, style = AppFont.xs)
                    }
                }
            }
            Text("Cancel", color = p.accentViolet, style = AppFont.body,
                modifier = Modifier.fillMaxWidth().noRippleClickable { onPick(null) }.padding(Space.s4), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
    }
}

private val chooserDay = SimpleDateFormat("EEE d MMM", Locale.getDefault())
private fun dayLabel(dayStart: Long): String {
    val today = dayStartMs(System.currentTimeMillis())
    return when (dayStart) {
        today -> "Today"
        today + 86_400_000L -> "Tomorrow"
        today - 86_400_000L -> "Yesterday"
        else -> DateFmt.dayHeader(Date(dayStart))
    }
}
internal fun dayStartMs(ms: Long): Long = Calendar.getInstance().apply {
    timeInMillis = ms; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
}.timeInMillis
internal fun isoOf(ms: Long): String = DateTimeFormatter.ISO_OFFSET_DATE_TIME.format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))
