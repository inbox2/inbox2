package com.inbox2.app.model

import com.inbox2.app.R
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Calendar status values stored by the engine — single source for the SQL filters. */
object CalendarStatusValue {
    /** `calendar_events.status` — a cancelled occurrence is hidden everywhere. */
    const val EVENT_CANCELLED = "cancelled"
    /** `calendars.status` — only active calendars are listed/toggled. */
    const val CALENDAR_ACTIVE = "active"
}

/** A meeting you can tap straight into: the conferencing link plus whose it is. */
data class EventMeeting(val url: String, val label: String) {
    /** Bundled brand logo (`drawable-nodpi/mtg_*.png`, rendered from the web
     *  `meetingProvider.js` glyphs; iOS EventMeeting.logo). Null for an unknown host. */
    val logo: Int?
        get() = when (label) {
            "Zoom" -> R.drawable.mtg_zoom
            "Google Meet" -> R.drawable.mtg_meet
            "Microsoft Teams" -> R.drawable.mtg_teams
            "Webex" -> R.drawable.mtg_webex
            else -> null
        }
}

/** Known conferencing hosts → brand name. Same table as the web
 *  `meetingProvider.js` HOSTS — first match wins. */
object MeetingHosts {
    private val TABLE = listOf(
        "zoom.us" to "Zoom", "zoom.com" to "Zoom",
        "teams.microsoft.com" to "Microsoft Teams", "teams.live.com" to "Microsoft Teams",
        "meet.google.com" to "Google Meet", "webex.com" to "Webex",
    )

    fun label(url: String): String? {
        val hay = url.lowercase()
        return TABLE.firstOrNull { hay.contains(it.first) }?.second
    }
}

/** Bare http(s) URLs in free text. Trailing sentence punctuation stays outside the
 *  match so "see https://x.com." doesn't capture the period (iOS Linkify.urlRE). */
val EVENT_URL_RE = Regex("https?://[^\\s<]+[^\\s<.,:;!?\"')\\]}]", RegexOption.IGNORE_CASE)

// A calendar event read from local SQLite (calendar_events ⋈ calendars). Times are
// ISO-8601; parsed once at construction (used on every grouping/sort/row render).
// Ported 1:1 from iOS CalendarEvent.swift.
class CalendarEvent(
    val id: String,
    val accountKey: String,
    val title: String,
    val startAt: String,
    val endAt: String,
    val allDay: Boolean,
    val location: String?,
    val organizerName: String?,
    val organizerEmail: String? = null,
    val detail: String?,
    val calendarColorHex: String?,
    val calendarName: String?,
    /** Raw `calendar_events.metadata` JSON (attendees + provider web link). Parsed
     *  on demand via `attendees` so the agenda/month-grid reads don't pay for it. */
    val metadataJSON: String? = null,
    /** The owning calendar accepts writes — gates Edit/Delete (read-only calendars 403). */
    val calendarWritable: Boolean = true,
) {
    val start: Date? = RelativeTime.parse(startAt)
    val end: Date? = RelativeTime.parse(endAt)

    /** True once the event has ended — drives the agenda's faded "already happened" look
     *  and its exclusion from the Upcoming list. All-day events use their end-of-day, so
     *  today's don't read as past (iOS CalendarEvent.isPast). */
    val isPast: Boolean
        get() {
            val e = end ?: start ?: return false
            return e.before(Date())
        }

    /** Local start-of-day, for agenda grouping. */
    val dayKey: Date = Calendar.getInstance().apply {
        time = start ?: Date(0)
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }.time

    val startTimeLabel: String
        get() = if (!allDay && start != null) DateFmt.hm(start) else "All day"

    val endTimeLabel: String
        get() = if (!allDay && start != null && end != null && end.after(start)) DateFmt.hm(end) else ""

    val rangeLabel: String
        get() = when {
            allDay -> "All day"
            endTimeLabel.isEmpty() -> startTimeLabel
            else -> "$startTimeLabel – $endTimeLabel"
        }

    /** Organizer to show — display name when present, else the email. Most Google
     *  imports carry only the email (name is null), so a bare name check hides the row. */
    val organizerLabel: String?
        get() = organizerName?.takeIf { it.isNotEmpty() } ?: organizerEmail?.takeIf { it.isNotEmpty() }

    /** Where to tap to get into this meeting (iOS CalendarEvent.meeting). A structured
     *  link recorded by the provider itself (`metadata.conference`, written by both
     *  syncers) wins; otherwise scan the free text, which is where an emailed invite or
     *  a pasted Zoom link puts it. Null for anything with no way in (a lunch, a room). */
    val meeting: EventMeeting?
        get() {
            val conf = metadataJSON?.let { runCatching { JSONObject(it).optJSONObject("conference") }.getOrNull() }
            val confUrl = conf?.let { if (it.isNull("url")) null else it.optString("url").takeIf(String::isNotEmpty) }
            if (confUrl != null) {
                val label = MeetingHosts.label(confUrl)
                    ?: conf.optString("label").takeIf { it.isNotEmpty() && !conf.isNull("label") }
                    ?: "meeting"
                return EventMeeting(confUrl, label)
            }
            // Descriptions arrive as HTML — decode the ampersand or a Zoom link loses
            // its `?pwd=` half.
            val hay = listOfNotNull(location, detail, title).joinToString(" ").replace("&amp;", "&")
            return EVENT_URL_RE.findAll(hay)
                .mapNotNull { m -> MeetingHosts.label(m.value)?.let { EventMeeting(m.value, it) } }
                .firstOrNull()
        }

    /** Meeting participants parsed from `metadataJSON`. Both syncers emit
     *  `{ "attendees": [{ email, name, responseStatus, organizer }] }` — MS omits
     *  `organizer` (falls back to false). Only the detail sheet calls this. */
    val attendees: List<EventAttendee>
        get() {
            val json = metadataJSON ?: return emptyList()
            return runCatching {
                val arr = JSONObject(json).optJSONArray("attendees") ?: return emptyList()
                (0 until arr.length()).mapNotNull { i ->
                    val a = arr.optJSONObject(i) ?: return@mapNotNull null
                    // isNull guard: optString turns an explicit JSON null into the
                    // literal string "null", which would win over the email fallback.
                    fun str(key: String): String? =
                        if (a.isNull(key)) null else a.optString(key).takeIf { it.isNotEmpty() }
                    EventAttendee(
                        email = str("email"),
                        name = str("name"),
                        responseStatus = str("responseStatus"),
                        isOrganizer = !a.isNull("organizer") && a.optBoolean("organizer", false),
                    )
                }
            }.getOrDefault(emptyList())
        }

    override fun equals(other: Any?) = other is CalendarEvent && other.id == id
    override fun hashCode() = id.hashCode()
}

/** One meeting participant, parsed from the `attendees` array inside an event's
 *  `metadata` JSON blob (populated identically by the Google + Microsoft syncers). */
data class EventAttendee(
    val email: String?,
    val name: String?,
    val responseStatus: String?,   // accepted | declined | tentative | needsAction
    val isOrganizer: Boolean,
) {
    /** Best human label — display name, else the email, else a placeholder. */
    val displayName: String
        get() = name?.takeIf { it.isNotEmpty() } ?: email?.takeIf { it.isNotEmpty() } ?: "Unknown"

    /** Icon cue for the RSVP state, mirroring the RSVP buttons (iOS statusIcon). */
    val statusIcon: String
        get() = when (responseStatus) {
            "accepted" -> "checkmark.circle.fill"
            "declined" -> "xmark.circle.fill"
            "tentative" -> "questionmark.circle"
            else -> "circle"
        }
}

/** A calendar that accepts writes (target for creating an event). */
data class WritableCalendar(
    val accountKey: String,
    val providerId: String,
    val name: String,
    val isPrimary: Boolean,
) {
    val id: String get() = providerId
}
