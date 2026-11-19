package com.inbox2.app.ui.screens

import com.inbox2.app.model.DateFmt
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.cloud.CloudZone
import com.inbox2.app.cloud.CloudZoneCategory
import com.inbox2.app.model.CalendarEvent
import com.inbox2.app.notify.ZoneAlerts
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// Zones: soft focus blocks on the calendar. They never block time — the agenda draws
// them as a tinted container around whatever meetings fall inside.

/** Wall-clock millis, re-read every [periodMs] (aligned to the period boundary). */
@Composable
internal fun rememberNow(periodMs: Long): Long {
    val now by produceState(System.currentTimeMillis()) {
        while (true) {
            delay(periodMs - System.currentTimeMillis() % periodMs)
            value = System.currentTimeMillis()
        }
    }
    return now
}

/** A zone category's colour in the current theme (palette key → shade). */
@Composable
internal fun zoneColor(category: CloudZoneCategory?): Color = theme.zone(category?.color)

/** Zone label text: the category colour pulled toward primary text so it reads on both themes. */
@Composable
internal fun zoneText(c: Color): Color = lerp(c, theme.textPrimary, 0.35f)

/** 14% fill + faint diagonal stripes (7%) — the zone look. Apply after `clip`. */
internal fun Modifier.zoneFill(c: Color) = drawBehind {
    drawRect(c.copy(alpha = 0.14f))
    val step = 10.dp.toPx()
    var x = -size.height
    while (x < size.width) {
        drawLine(c.copy(alpha = 0.07f), Offset(x, size.height), Offset(x + size.height, 0f), 3.dp.toPx())
        x += step
    }
}


/** "1:41 left" / "12 min left". */
internal fun leftLabel(ms: Long): String {
    val mins = (ms + 59_999) / 60_000
    return if (mins >= 60) "%d:%02d left".format(mins / 60, mins % 60) else "$mins min left"
}

/** One agenda line: a loose event, or a zone with the events that start inside it. */
internal sealed interface DayEntry { val startMs: Long }
internal class EventEntry(val event: CalendarEvent) : DayEntry { override val startMs = event.start?.time ?: 0L }
internal class ZoneEntry(val zone: CloudZone, val events: List<CalendarEvent>) : DayEntry { override val startMs = zone.startMs }

/** A day's events + zones in time order, each timed event nested in the first zone it
 *  starts inside. Zones with nothing inside still show, as their own block. */
internal fun dayEntries(events: List<CalendarEvent>, zones: List<CloudZone>): List<DayEntry> {
    val sorted = zones.sortedBy { it.startMs }
    val inside = HashMap<String, MutableList<CalendarEvent>>()
    val loose = mutableListOf<DayEntry>()
    events.forEach { e ->
        val s = e.start?.time
        val z = if (e.allDay || s == null) null else sorted.firstOrNull { s >= it.startMs && s < it.endMs }
        if (z == null) loose += EventEntry(e) else inside.getOrPut(z.id) { mutableListOf() } += e
    }
    return (sorted.map { ZoneEntry(it, inside[it.id].orEmpty()) } + loose).sortedBy { it.startMs }
}

/** Agenda zone container: category, name, time, note, then the meetings inside. A
 *  zone running now gets a stronger outline, an "N left" pill and a progress bar. */
@Composable
internal fun ZoneBlock(
    zone: CloudZone,
    category: CloudZoneCategory?,
    onOpen: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val p = theme
    val c = zoneColor(category)
    val now = rememberNow(30_000)
    val active = zone.isActive(now)
    val shape = RoundedCornerShape(Radius.xl)
    Column(
        Modifier.fillMaxWidth().clip(shape).zoneFill(c)
            .border(if (active) 1.5.dp else 1.dp, c.copy(alpha = if (active) 0.85f else 0.45f), shape)
            .alpha(if (zone.endMs < now) 0.5f else 1f),
    ) {
        Column(Modifier.fillMaxWidth().noRippleClickable { onOpen() }.padding(Space.s3)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(7.dp).clip(CircleShape).background(c))
                Spacer(Modifier.width(Space.s2))
                Text((category?.name ?: "Zone").uppercase(), color = zoneText(c),
                    style = AppFont.xs3.copy(letterSpacing = 0.7.sp), modifier = Modifier.weight(1f))
                if (active) Text(leftLabel(zone.endMs - now), color = zoneText(c), style = AppFont.xs3,
                    modifier = Modifier.clip(RoundedCornerShape(Radius.full)).background(c.copy(alpha = 0.22f))
                        .padding(horizontal = Space.s2, vertical = 2.dp))
            }
            Text(zone.name, color = p.textPrimary, style = AppFont.md, maxLines = 2, modifier = Modifier.padding(top = Space.s1))
            Text("${DateFmt.hm(zone.startMs)} – ${DateFmt.hm(zone.endMs)}", color = p.textTertiary, style = AppFont.xs)
            zone.note?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = p.textSecondary, style = AppFont.xs, maxLines = 3, modifier = Modifier.padding(top = 2.dp))
            }
        }
        Column(Modifier.padding(horizontal = Space.s2).padding(bottom = Space.s2),
            verticalArrangement = Arrangement.spacedBy(Space.s2), content = content)
        if (active) ZoneProgress(c, (now - zone.startMs).toFloat() / (zone.endMs - zone.startMs))
    }
}

@Composable
private fun ZoneProgress(c: Color, fraction: Float) {
    Box(Modifier.fillMaxWidth().height(2.dp).background(c.copy(alpha = 0.2f))) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).fillMaxHeight().background(c))
    }
}

/** Sticky card at the top of the app while a notify zone runs and isn't marked Done
 *  (same dismissed set as the notification's Done). Once the zone ends the card stays,
 *  as "Zone ended", until Done — for zones whose alert was posted ([ZoneAlerts.shown]),
 *  so a zone that ended unseen yesterday doesn't pop up. Overlapping zones: the one
 *  that started most recently wins (as on web). Owns its own clock so the tick only
 *  recomposes this card. */
@Composable
fun ActiveZoneCard(cloud: CloudSession, onOpenCalendar: () -> Unit) {
    val p = theme
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val zones by cloud.upcomingZones.collectAsState()
    val categories by cloud.zoneCategories.collectAsState()
    val dismissed by ZoneAlerts.dismissed(ctx).collectAsState()
    val shown by ZoneAlerts.shown(ctx).collectAsState()
    val now = rememberNow(1_000)
    val zone = zones.filter {
        it.notify && it.startMs <= now && it.id !in dismissed.orEmpty() && (it.endMs > now || it.id in shown.orEmpty())
    }.maxByOrNull { it.startMs } ?: return
    val ended = zone.endMs <= now
    val category = categories.firstOrNull { it.id == zone.categoryId }
    val c = zoneColor(category)
    val shape = RoundedCornerShape(Radius.xl)
    val left = (zone.endMs - now) / 1000
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Space.s4, vertical = Space.s2)
            .clip(shape).background(p.bgRaised).zoneFill(c).border(1.5.dp, c.copy(alpha = 0.85f), shape),
    ) {
        Row(Modifier.padding(Space.s3), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Row(Modifier.clip(RoundedCornerShape(Radius.full)).background(c.copy(alpha = 0.22f))
                        .padding(horizontal = Space.s2, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(6.dp).clip(CircleShape).background(c))
                        Spacer(Modifier.width(Space.s1))
                        Text(category?.name ?: "Zone", color = zoneText(c), style = AppFont.xs3)
                    }
                    Spacer(Modifier.width(Space.s2))
                    Text(if (ended) "Zone ended" else "You're in the zone", color = p.textTertiary, style = AppFont.xs2)
                }
                Text(zone.name, color = p.textPrimary, style = AppFont.md, maxLines = 1, modifier = Modifier.padding(top = Space.s1))
                zone.note?.takeIf { it.isNotBlank() }?.let { Text(it, color = p.textSecondary, style = AppFont.xs, maxLines = 2) }
            }
            Column(horizontalAlignment = Alignment.End) {
                if (!ended) Text("%d:%02d:%02d".format(left / 3600, left / 60 % 60, left % 60), color = zoneText(c),
                    style = AppFont.mono(15, FontWeight.SemiBold))
            }
        }
        // Plain text links, not buttons — deliberately low-key so Done isn't an easy tap.
        // TextButton keeps the 48dp touch target with no fill or border.
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s1), horizontalArrangement = Arrangement.End) {
            ZoneLink("Open calendar", onOpenCalendar)
            ZoneLink("Done") { ZoneAlerts.dismiss(ctx, zone.id, zone.endMs) }
        }
        ZoneProgress(c, (now - zone.startMs).toFloat() / (zone.endMs - zone.startMs))
    }
}

@Composable
private fun ZoneLink(label: String, onClick: () -> Unit) {
    TextButton(onClick, contentPadding = PaddingValues(horizontal = Space.s2),
        colors = ButtonDefaults.textButtonColors(contentColor = theme.textSecondary)) {
        Text(label, style = AppFont.ui(13, FontWeight.Medium))
    }
}
