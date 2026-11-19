package com.inbox2.app.model

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.Date
import java.util.Locale

// Parse "Display Name <email@host>" headers + derive avatar initials / a stable color
// seed. Ported 1:1 from iOS MailAddress (Conversation.swift). Dependency-free.
object MailAddress {
    data class Parsed(val name: String, val email: String)

    fun parse(raw: String): Parsed {
        val trimmed = raw.trim()
        val open = trimmed.indexOf('<')
        val close = trimmed.indexOf('>')
        if (open < 0 || close < 0 || open >= close) {
            return Parsed(trimmed.ifEmpty { "Unknown" }, trimmed)
        }
        val email = trimmed.substring(open + 1, close).trim()
        var name = trimmed.substring(0, open).trim()
        name = if (name.length >= 2 && name.startsWith('"') && name.endsWith('"'))
            // One quoted-string: drop the pair, then unescape `\"`/`\\` (see `format`).
            name.substring(1, name.length - 1).replace(Regex("""\\(.)"""), "$1")
        else name.trim('"', '\'')
        if (name.isEmpty()) name = email
        return Parsed(name, email)
    }

    /** Split an address list on commas outside quotes/angle brackets, keeping
     *  `"Doe, Jane" <j@x>` one entry. Raw parts, trailing (possibly empty) part kept. */
    fun splitList(raw: String): List<String> {
        val parts = mutableListOf<String>()
        val current = StringBuilder()
        var inAngle = false
        var inQuote = false
        var escaped = false
        for (ch in raw) {
            if (escaped) { escaped = false; current.append(ch); continue }
            when (ch) {
                '\\' -> if (inQuote) escaped = true
                '"' -> inQuote = !inQuote
                '<' -> inAngle = true
                '>' -> inAngle = false
                ',' -> if (!inAngle && !inQuote) { parts.add(current.toString()); current.clear(); continue }
            }
            current.append(ch)
        }
        parts.add(current.toString())
        return parts
    }

    /** Split a comma-separated recipient header, keeping `"Doe, Jane" <j@x>` intact. */
    fun parseList(raw: String): List<Parsed> =
        splitList(raw).filter { it.isNotBlank() }.map { parse(it) }.filter { it.email.contains("@") }

    private val atext = Regex("^[A-Za-z0-9_ !#$%&'*+\\-/=?^`{|}~]+$")

    /** `Name <addr>`, the name RFC 5322-quoted when it holds anything a list would
     *  split on (`"Veger, Nick" <v@x>`). Mirrors web `formatMailbox`. */
    fun format(name: String, email: String): String = when {
        name.isEmpty() -> email
        atext.matches(name) -> "$name <$email>"
        else -> "\"${name.replace("\\", "\\\\").replace("\"", "\\\"")}\" <$email>"
    }

    fun initials(raw: String): String {
        val name = parse(raw).name
        val parts = name.split(' ', '.', '@').filter { it.isNotEmpty() }
        if (parts.size >= 2) {
            return (parts[0].take(1) + parts[1].take(1)).uppercase()
        }
        return name.take(2).uppercase()
    }

    /** Deterministic small int (djb2) so the same sender keeps the same ring color. */
    fun seed(key: String): Int {
        var h = 5381L
        for (b in key.encodeToByteArray()) h = ((h shl 5) + h) + b.toInt()
        return kotlin.math.abs(h.toInt())
    }
}

// Cached, thread-safe formatters (a SimpleDateFormat per call allocated garbage on
// every list row, and SimpleDateFormat isn't thread-safe anyway; minSdk 26 has
// java.time natively). ponytail: locale is captured at class-init — Android restarts
// the process on a system language change, so a live switch isn't worth handling.
private val TIME_FMT = DateTimeFormatter.ofPattern("h:mm a", Locale.getDefault())
private val WEEKDAY_FMT = DateTimeFormatter.ofPattern("EEE", Locale.getDefault())
private val MONTH_DAY_FMT = DateTimeFormatter.ofPattern("MMM d", Locale.getDefault())
private val MONTH_DAY_YEAR_FMT = DateTimeFormatter.ofPattern("MMM d, yyyy", Locale.getDefault())
private val LONG_DATE_FMT = DateTimeFormatter.ofPattern("EEE, MMM d, yyyy", Locale.getDefault())
private val DAY_HEADER_FMT = DateTimeFormatter.ofPattern("EEEE, d MMM", Locale.getDefault())
private val DAY_HEADER_YEAR_FMT = DateTimeFormatter.ofPattern("EEEE, d MMM yyyy", Locale.getDefault())
private val HM_FMT = DateTimeFormatter.ofPattern("HH:mm", Locale.getDefault())
private fun Date.fmt(f: DateTimeFormatter): String = f.format(toInstant().atZone(ZoneId.systemDefault()))

/** The one home for the `HH:mm` / `EEEE, d MMM` patterns (zones, event rows, alerts,
 *  the Day view header) — previously a `SimpleDateFormat` per call site. */
object DateFmt {
    /** "14:05" — 24h wall clock. */
    fun hm(d: Date): String = d.fmt(HM_FMT)
    fun hm(ms: Long): String = hm(Date(ms))
    /** "Monday, 9 Jun". */
    fun dayHeader(d: Date): String = d.fmt(DAY_HEADER_FMT)
}

// Compact relative timestamps for list rows ("9:14 AM", "Mon", "May 3"). Mirrors iOS
// RelativeTime — tolerates fractional-seconds + the date-only all-day form.
object RelativeTime {
    fun parse(iso: String): Date? {
        if (iso.isEmpty()) return null
        // Try offset date-time, then date-only (all-day events) in the local zone.
        runCatching { return Date.from(Instant.from(DateTimeFormatter.ISO_OFFSET_DATE_TIME.parse(iso))) }
        runCatching {
            val ld = java.time.LocalDate.parse(iso)
            return Date.from(ld.atStartOfDay(ZoneId.systemDefault()).toInstant())
        }
        runCatching { return Date.from(Instant.parse(iso)) }
        // A floating wall clock with no zone (a floating ICS time or a detected
        // meeting): read in the device's zone, as RFC 5545 says.
        runCatching {
            return Date.from(java.time.LocalDateTime.parse(iso).atZone(ZoneId.systemDefault()).toInstant())
        }
        return null
    }

    fun short(iso: String): String {
        val date = parse(iso) ?: return ""
        val cal = Calendar.getInstance()
        val today = Calendar.getInstance()
        cal.time = date
        val now = Date()
        fun sameDay(a: Calendar, b: Calendar) =
            a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
        val yesterday = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }
        val daysAgo = ((now.time - date.time) / (1000L * 60 * 60 * 24)).toInt()
        val fmt = when {
            sameDay(cal, today) -> TIME_FMT
            sameDay(cal, yesterday) -> return "Yesterday"
            daysAgo in 0..6 -> WEEKDAY_FMT
            cal.get(Calendar.YEAR) == today.get(Calendar.YEAR) -> MONTH_DAY_FMT
            else -> MONTH_DAY_YEAR_FMT
        }
        return date.fmt(fmt)
    }

    /** ("Wed, Jun 10, 2026", "9:33 AM") for the reader's date row, which sets the
     *  date and time in the code font around a normal-font "at". Mirrors iOS. */
    /** An invite time: a local-channel ICS keeps the sender's `TZID`, so `start`/`end`
     *  are a bare wall clock read in [zone] (core ics.rs), not in the device's zone. */
    fun parse(iso: String, zone: String?): Date? {
        if (zone != null) runCatching {
            return Date.from(java.time.LocalDateTime.parse(iso).atZone(ZoneId.of(zone)).toInstant())
        }
        return parse(iso)
    }

    fun longParts(iso: String, zone: String? = null): Pair<String, String>? {
        val date = parse(iso, zone) ?: return null
        return date.fmt(LONG_DATE_FMT) to date.fmt(TIME_FMT)
    }
}

/** Friendly day-section headers ("Today", "Tomorrow", "Monday, 9 Jun"). */
object DayHeader {
    fun label(day: Date): String {
        val cal = Calendar.getInstance().apply { time = day }
        val today = Calendar.getInstance()
        val tomorrow = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, 1) }
        val yesterday = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }
        fun sameDay(a: Calendar, b: Calendar) =
            a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
        return when {
            sameDay(cal, today) -> "Today"
            sameDay(cal, tomorrow) -> "Tomorrow"
            sameDay(cal, yesterday) -> "Yesterday"
            cal.get(Calendar.YEAR) == today.get(Calendar.YEAR) -> day.fmt(DAY_HEADER_FMT)
            else -> day.fmt(DAY_HEADER_YEAR_FMT)
        }
    }
}
