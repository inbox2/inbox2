package com.inbox2.app.model

import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * A repeating event's rule as the event sheet edits it, and the RFC 5545 RRULE
 * body it saves as (`FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2`, no `RRULE:`). Mirrors iOS
 * `RepeatRule` and web `lib/recurrence.js`; the Rust core turns the body into
 * Google's `recurrence` or Graph's pattern + range.
 */
data class RepeatRule(
    val freq: Freq = Freq.NONE,
    val interval: Int = 1,
    /** Weekly days (MO…SU); empty = the start's own weekday. */
    val days: Set<String> = emptySet(),
    val ends: Ends = Ends.NEVER,
    val until: LocalDate = LocalDate.now(),
    val count: Int = 2,
    /** The untouched body of a [Freq.CUSTOM] rule. */
    val customRule: String? = null,
    /** WKST as read, kept on rebuild: it decides which weeks an every-N-weeks series
     *  falls in, and the sheet has no control for it. */
    val wkst: String? = null,
) {
    enum class Freq(val code: String, val label: String, val unit: String) {
        NONE("", "Does not repeat", ""),
        DAILY("DAILY", "Daily", "day"),
        WEEKLY("WEEKLY", "Weekly", "week"),
        MONTHLY("MONTHLY", "Monthly", "month"),
        YEARLY("YEARLY", "Yearly", "year"),
        /** A rule set elsewhere the sheet can't draw (2nd Tuesday, …): kept as is. */
        CUSTOM("", "Custom (as set elsewhere)", ""),
    }

    enum class Ends(val label: String) { NEVER("Never"), ON("On date"), AFTER("After") }

    fun activeDays(start: Long): Set<String> = days.ifEmpty { setOf(weekdayCode(start)) }

    /** The RRULE body, or null for no repeat. `until` means "through that day":
     *  a DATE for an all-day series, that day's last second in UTC otherwise. */
    fun rrule(start: Long, allDay: Boolean): String? {
        if (freq == Freq.NONE) return null
        if (freq == Freq.CUSTOM) return customRule
        val parts = mutableListOf("FREQ=${freq.code}")
        if (interval > 1) parts += "INTERVAL=$interval"
        if (freq == Freq.WEEKLY) {
            val picked = activeDays(start)
            parts += "BYDAY=" + WEEKDAYS.map { it.first }.filter { it in picked }.joinToString(",")
            wkst?.let { parts += "WKST=$it" }
        }
        when (ends) {
            Ends.AFTER -> parts += "COUNT=${count.coerceAtLeast(1)}"
            Ends.ON -> {
                // Never before the start's own day: a series that never happens.
                val last = maxOf(until, localDate(start))
                parts += "UNTIL=" + if (allDay) last.format(DateTimeFormatter.BASIC_ISO_DATE)
                    else last.atTime(LocalTime.of(23, 59, 59)).atZone(ZoneId.systemDefault())
                        .withZoneSameInstant(ZoneOffset.UTC).format(UTC_STAMP)
            }
            Ends.NEVER -> {}
        }
        return parts.joinToString(";")
    }

    companion object {
        /** Monday first: RRULE code + the sheet's one-letter label. */
        val WEEKDAYS = listOf("MO" to "M", "TU" to "T", "WE" to "W", "TH" to "T", "FR" to "F", "SA" to "S", "SU" to "S")
        private val UTC_STAMP = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'")
        private val KNOWN = setOf("FREQ", "INTERVAL", "BYDAY", "COUNT", "UNTIL", "WKST", "BYMONTHDAY", "BYMONTH")

        fun localDate(ms: Long): LocalDate = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate()

        fun weekdayCode(ms: Long): String {
            val dow = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).dayOfWeek
            return WEEKDAYS[dow.value - DayOfWeek.MONDAY.value].first
        }

        /** A series' rule as sheet state, for an event starting at [startMs]; one the
         *  sheet can't draw (2nd Tuesday, the 15th of a series starting on the 1st)
         *  comes back CUSTOM and is saved untouched. */
        fun parse(rule: String?, startMs: Long): RepeatRule {
            val body = rule.orEmpty().trim().removePrefix("RRULE:")
            if (body.isEmpty()) return RepeatRule()
            val parts = body.split(';').mapNotNull { p ->
                p.split('=', limit = 2).takeIf { it.size == 2 }?.let { it[0].uppercase() to it[1] }
            }.toMap()
            val custom = RepeatRule(freq = Freq.CUSTOM, customRule = body)
            val f = Freq.entries.firstOrNull { it.code.isNotEmpty() && it.code == parts["FREQ"] } ?: return custom
            if (!KNOWN.containsAll(parts.keys)) return custom
            // BYMONTHDAY/BYMONTH (Graph's absolute patterns read back) only when they
            // are the start's own day and month — what the sheet repeats on.
            val first = localDate(startMs)
            // …and only where they mean that: a month day on a monthly/yearly rule,
            // a month on a yearly one. Anywhere else they filter.
            if (parts["BYMONTHDAY"]?.let { it != first.dayOfMonth.toString() || f !in setOf(Freq.MONTHLY, Freq.YEARLY) } == true) return custom
            if (parts["BYMONTH"]?.let { it != first.monthValue.toString() || f != Freq.YEARLY } == true) return custom
            val days = parts["BYDAY"]?.split(',')?.map { it.trim().uppercase() }.orEmpty()
            if (days.isNotEmpty() && (f != Freq.WEEKLY || days.any { d -> WEEKDAYS.none { it.first == d } })) return custom
            val base = RepeatRule(freq = f, interval = parts["INTERVAL"]?.toIntOrNull() ?: 1, days = days.toSet(), wkst = parts["WKST"])
            parts["COUNT"]?.toIntOrNull()?.let { return base.copy(ends = Ends.AFTER, count = it) }
            val u = parts["UNTIL"] ?: return base
            // A timed UNTIL is a UTC instant; its local day is the one picked.
            val day = runCatching {
                if (u.length > 8) java.time.LocalDateTime.parse(u, UTC_STAMP).atOffset(ZoneOffset.UTC)
                    .atZoneSameInstant(ZoneId.systemDefault()).toLocalDate()
                else LocalDate.parse(u.take(8), DateTimeFormatter.BASIC_ISO_DATE)
            }.getOrNull() ?: return base
            return base.copy(ends = Ends.ON, until = day)
        }
    }
}
