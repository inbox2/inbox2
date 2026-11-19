package com.inbox2.app.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Shared row models read from the local SQLite store (InboxStore). Ported 1:1 from
// the iOS Models/Conversation.swift + CalendarEvent.swift — field names map to the
// `conversations` / `messages` / `calendar_events` columns; display values derive
// lazily so the read layer stays a thin projection. See docs/iOS-App.md §5.

/**
 * Account-key routing: inbox2 "MX" team-pool keys are prefixed `org_` (the whole-org
 * chip) or `dom_` (a per-domain workspace chip). Everything else is an offline channel.
 */
object AccountKey {
    const val DOMAIN_PREFIX = "org_"
    const val DOMAIN_WORKSPACE_PREFIX = "dom_"
    fun isDomain(key: String?): Boolean =
        key?.startsWith(DOMAIN_PREFIX) == true || key?.startsWith(DOMAIN_WORKSPACE_PREFIX) == true

    /** The `dom_…` list filter when a specific domain workspace is selected; null for
     *  the whole-org (legacy) chip, which shows the unfiltered pool. */
    fun domainFilter(key: String?): String? =
        if (key?.startsWith(DOMAIN_WORKSPACE_PREFIX) == true) key else null
}

/** Conversation lifecycle status — mirrors the engine's `ConversationStatus`. */
object ConvStatusValue {
    const val OPEN = "open"
    const val ARCHIVED = "archived"
    const val SPAM = "spam"
    const val TRASH = "trash"

    /** Hidden from inbox + unified list. */
    val inboxHidden = listOf(TRASH, SPAM, ARCHIVED)
    /** "Not real mail" (search excludes these but keeps archived). */
    val discarded = listOf(TRASH, SPAM)
}

/** Outbox delivery status — mirrors the engine's `OutboxStatus`. */
object OutboxStatusValue {
    const val PENDING = "pending"
    const val SENDING = "sending"
    const val SENT = "sent"
    const val FAILED = "failed"

    /** Actionable queue — everything not yet delivered. */
    val queued = listOf(PENDING, SENDING, FAILED)
}

/** Row/header badge derived from priority flags + AI state. */
enum class ConvStatus(val label: String) {
    OPEN("Open"), PENDING("Pending"), URGENT("Urgent"), AI("AI"), ARCHIVED("Archived")
}

/** Eisenhower triage quadrant — matches the desktop `lib/priority.js` keys. */
// Glyphs match the desktop Eisenhower quadrants (web lib/priority.js) and
// MailFolder's triage views, so the same quadrant never wears two icons.
enum class Quadrant(val raw: String, val label: String, val icon: String) {
    DO_FIRST("DO_FIRST", "Priority", "flame.fill"),
    SCHEDULE("SCHEDULE", "Schedule", "calendar.badge.clock"),
    DELEGATE("DELEGATE", "Delegate", "person.badge.plus"),
    LATER("LATER", "Later", "clock");

    companion object {
        fun fromRaw(raw: String?) = entries.firstOrNull { it.raw == raw }
    }
}

data class Conversation(
    val id: String,
    val accountKey: String,
    val fromAddress: String,
    val toAddress: String,
    val subject: String,
    val snippet: String,
    val status: String,
    val unread: Boolean,
    val hasAttachment: Boolean,
    val priorityUrgent: Boolean,
    val priorityImportant: Boolean,
    val aiSummary: String?,
    val triageLabel: String?,
    val aiSummaryMedium: String?,
    val aiSummaryShort: String?,
    val createdAt: String,
    val updatedAt: String,
    val messageCount: Int,
    /** Whether the AI summaries were generated for the LATEST message (the core's
     *  ai_meta_msg_key currency rule). Populated by InboxStore.conversation(key)
     *  only; list queries leave the default. */
    val summariesCurrent: Boolean = true,
    /** Jev priority score 0–4; null until scored (docs/Triage.md). */
    val triagePriority: Double? = null,
    /** Due date the next-action pass found in the mail (`next_action_due_on`, "2026-10-24"); Lore ranks near deadlines higher. */
    val dueOn: String? = null,
    /** The member ticked this personal-bucket thread off in Lore (`lore_done`, MX only). */
    val loreDone: Boolean = false,
) {
    val sender: String get() = MailAddress.parse(fromAddress).name
    val email: String get() = MailAddress.parse(fromAddress).email
    val initials: String get() = MailAddress.initials(fromAddress)
    val seed: Int get() = MailAddress.seed(email.ifEmpty { id })
    val time: String get() = RelativeTime.short(updatedAt)

    /** The one line of body text shown under the subject in a list row: the triage
     *  worker's generated one-liner once it exists, else the raw body snippet — so a
     *  row starts with the snippet and upgrades in place when triage lands.
     *  A model-less triage run writes the SUBJECT as [aiSummaryShort] (see
     *  `deterministic_summaries` in the core), which would render as
     *  "Subject / Subject"; those echoes keep the snippet. Mirrors the web
     *  `conversationPreview()` and the iOS `preview`. */
    val preview: String
        get() {
            val summary = aiSummaryShort.orEmpty().trim().removeSuffix("…")
            if (summary.isEmpty() || subject.trim().startsWith(summary, ignoreCase = true)) return snippet
            return summary
        }

    val isDomain: Boolean get() = AccountKey.isDomain(accountKey)
    val isRestorable: Boolean get() = status in ConvStatusValue.inboxHidden

    /** Parsed built-in triage label, or null when unprocessed or a custom slug. */
    val triage: com.inbox2.app.engine.TriageLabel?
        get() = com.inbox2.app.engine.TriageLabel.from(triageLabel)

    /** Urgent/High chip from the Jev priority score, or null. */
    val priority: com.inbox2.app.engine.TriagePriority?
        get() = com.inbox2.app.engine.TriagePriority.from(triagePriority)

    /** Visual badge in priority order: urgent → AI-handled → important. */
    val badge: ConvStatus?
        get() = when {
            status == ConvStatusValue.ARCHIVED -> ConvStatus.ARCHIVED
            priorityUrgent -> ConvStatus.URGENT
            !aiSummary.isNullOrEmpty() -> ConvStatus.AI
            priorityImportant -> ConvStatus.PENDING
            else -> null
        }
}

data class Message(
    val id: String,
    val fromAddress: String,
    val toAddress: String,
    val ccAddress: String?,
    val subject: String,
    val bodyPlain: String?,
    val bodyHTML: String?,
    val isInbound: Boolean,
    val isDraft: Boolean,
    val createdAt: String,
    val sentimentLabel: String?,
    val intentLabel: String?,
    /** A pre-parsed meeting invite carried on domain (MX) messages from the API;
     *  null for local-channel messages, which resolve it lazily from the message's
     *  text/calendar attachment via the core (docs/Meeting-Invites.md). */
    val invite: ClientInvite? = null,
    /** A meet-link booking request (MX only) — Accept/Decline banner in the reader. */
    val meetingRequest: ClientMeetingRequest? = null,
) {
    val sender: String get() = MailAddress.parse(fromAddress).name
    val email: String get() = MailAddress.parse(fromAddress).email
    val initials: String get() = MailAddress.initials(fromAddress)
    val seed: Int get() = MailAddress.seed(email.ifEmpty { id })
    val time: String get() = RelativeTime.short(createdAt)

    /** true/false if classified on-device, else null (no badge). */
    val sentimentPositive: Boolean?
        get() = when (sentimentLabel?.uppercase()) {
            "POSITIVE" -> true
            "NEGATIVE" -> false
            else -> null
        }

    /** Normalized intent kind for the AI badge, or null when unclassified. */
    val intentKind: IntentKind? get() = IntentKind.from(intentLabel)

    /** Best body for the WebView reader — HTML preferred, else wrapped plain text. */
    val bodyForReader: String
        get() {
            bodyHTML?.takeIf { it.isNotEmpty() }?.let { return it }
            val plain = bodyPlain.takeUnless { it.isNullOrEmpty() } ?: "(No content)"
            val escaped = plain
                .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            return "<div style=\"white-space:pre-wrap\">$escaped</div>"
        }
}

/** A meet-link booking request (docs/Calendar.md): nothing is on the calendar yet;
 *  the invitee accepts (creates the event + mails an ICS invite) or declines. Mirrors
 *  the API `MeetingRequest#banner_payload` and iOS `ClientMeetingRequest`. */
@Serializable
data class ClientMeetingRequest(
    val key: String,
    val name: String? = null,
    val note: String? = null,
    val start: String? = null,
    val end: String? = null,
    @SerialName("visitor_timezone") val visitorTimezone: String? = null,
    @SerialName("conference_mode") val conferenceMode: String? = null,
    val status: String? = null,
)

/**
 * A parsed emailed meeting invite (VEVENT) + the user's RSVP state — the single
 * shape behind the Accept/Tentative/Decline banner, from either source: MX messages
 * carry it pre-parsed on the API `invite` object (`rsvp_status`); local-channel
 * messages resolve it from the core as a JSON `ClientInvite` (`current_status` +
 * `attachment_id`). Keys are the core/Rails snake_case. See docs/Meeting-Invites.md.
 */
@Serializable
data class ClientInvite(
    val method: String? = null,
    val uid: String? = null,
    val summary: String? = null,
    val description: String? = null,
    val location: String? = null,
    val start: String? = null,
    val end: String? = null,
    /** IANA zone [start]/[end] are in — only set when the ICS said so (`TZID`, or `UTC`
     *  for a `Z` time). A floating time has none, by RFC 5545. */
    val timezone: String? = null,
    @SerialName("all_day") val allDay: Boolean = false,
    @SerialName("organizer_email") val organizerEmail: String? = null,
    @SerialName("organizer_name") val organizerName: String? = null,
    val sequence: Int = 0,
    @SerialName("matched_event_key") val matchedEventKey: String? = null,
    @SerialName("current_status") val currentStatus: String? = null,  // local channels
    @SerialName("rsvp_status") val rsvpStatus: String? = null,        // MX (cloud)
    @SerialName("attachment_id") val attachmentId: String? = null,    // local only
    /** No ICS at all: triage read the meeting out of the body (docs/Meeting-Invites.md
     *  "Detected meetings"). Always a PUBLISH, so it only offers "Add to calendar". */
    val detected: Boolean = false,
) {
    /** An invitation you can actually answer. A stated METHOD other than REQUEST
     *  (PUBLISH confirmations, bookings, tickets) is never answerable. Past that, an
     *  MX invite is a REQUEST by construction, while a local-channel one also has to
     *  name an organizer — an RSVP with nobody to send it to isn't worth offering.
     *  Kept in step with the web `isRequest` and iOS `ClientInvite.isRequest`. */
    val isRequest: Boolean
        get() = when {
            method != null && method != "REQUEST" -> false
            attachmentId == null -> true // MX
            else -> !organizerEmail.isNullOrEmpty()
        }

    /** [start]/[end] as instants, read in the invite's own zone (web `inviteInstant`). */
    /** All-day reads only the date, as your midnight (MX sends it as `…T00:00:00Z`). */
    val startDate: java.util.Date? get() = start?.let(::instant)
    val endDate: java.util.Date? get() = end?.let(::instant)
    private fun instant(s: String): java.util.Date? =
        if (allDay) RelativeTime.parse(s.take(10)) else RelativeTime.parse(s, timezone)

    /** The other half of the banner: a `text/calendar` that isn't asking for an answer
     *  — an appointment confirmation, a booking, a ticket — so the useful action is
     *  putting it on your calendar. */
    val isAddable: Boolean get() = !isRequest

    /** The answered response, or null when unanswered ("needs_action"). */
    val answeredStatus: String? get() = (rsvpStatus ?: currentStatus)?.takeIf { it != "needs_action" }
}

data class Contact(val email: String, val name: String, val total: Int) {
    val id: String get() = email
    val formatted: String
        get() = if (name.isEmpty() || name.lowercase() == email) email else "$name <$email>"
}

data class AttachmentInfo(
    val attachmentId: String,
    val filename: String,
    val mimeType: String,
    val size: Int,
) {
    val id: String get() = attachmentId
    val sizeLabel: String get() = byteSizeLabel(size)
}

/** "812 B" / "24 KB" / "1.3 MB" (iOS ByteCountFormatter .file). */
fun byteSizeLabel(bytes: Int): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "%.0f KB".format(bytes / 1024.0)
    else -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
}

data class ActivityEntry(
    val id: String,
    val fromAddress: String,
    val createdAt: String,
    val conversationKey: String,
    val subject: String,
    val unread: Boolean,
) {
    val sender: String get() = MailAddress.parse(fromAddress).name
    val initials: String get() = MailAddress.initials(fromAddress)
    val seed: Int get() = MailAddress.seed(MailAddress.parse(fromAddress).email)
    val time: String get() = RelativeTime.short(createdAt)
    val text: String get() = "$sender · $subject"
}

/** Inbox filter pills — no flag concept; the third scope is Triaged. */
enum class InboxFilter(val label: String) { ALL("All"), UNREAD("Unread"), TRIAGED("Triaged") }

/**
 * On-device intent classification kinds (the rules engine's intent vocabulary),
 * normalized from the stored label. Single source for the badge label + glyph,
 * so the model layer and the badge UI can't drift apart.
 */
enum class IntentKind(val raw: String, val label: String, val sfIcon: String) {
    QUESTION("question", "Question", "questionmark.circle"),
    REQUEST("request", "Request", "tray.and.arrow.down"),
    COMPLAINT("complaint", "Complaint", "exclamationmark.bubble"),
    SCHEDULING("scheduling", "Scheduling", "calendar"),
    FYI("fyi", "FYI", "info.circle");

    companion object {
        /** Normalize a stored intent label; null = unclassified / junk ("<intent>", "other"). */
        fun from(raw: String?): IntentKind? {
            val r = raw?.lowercase()
            if (r.isNullOrEmpty() || r == "<intent>" || r == "other") return null
            return entries.firstOrNull { it.raw == r } ?: FYI
        }
    }
}
