package com.inbox2.app.cloud

import com.inbox2.app.model.ClientInvite
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConvStatusValue
import com.inbox2.app.model.Message
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Models for the inbox2-domain ("MX") REST API (iOS CloudModels). Field names map to the
// Rails serializers (snake_case). Domain mail is always live from the API — distinct from
// the offline-channel SQLite models, but mapped onto the same shared row/reader models so
// the existing UI renders domain mail unchanged.

@Serializable
data class CloudUser(
    val id: String,
    val username: String,
    @SerialName("display_name") val displayName: String? = null,
    @SerialName("billing_email") val billingEmail: String? = null,
) {
    val label: String get() = displayName?.takeIf { it.isNotEmpty() } ?: username
}

/**
 * A first-class domain within an org's MX pool. An org owns many equal domains;
 * each becomes its own workspace chip in the inbox rail (parity with the web
 * per-domain tabs). `id` is the domain's `dom_…` public key — used as the
 * `?domain=` list filter.
 */
@Serializable
data class CloudDomain(
    val id: String,
    val name: String,
    val slug: String? = null,
    val status: String? = null,
    @SerialName("icon_url") val iconUrl: String? = null,
)

@Serializable
data class CloudOrg(
    val id: String,
    val name: String,
    val slug: String? = null,
    val domain: String? = null,
    @SerialName("icon_url") val iconUrl: String? = null,
    // All first-class domains in the org (empty for legacy single-domain payloads
    // → the rail falls back to one org-keyed chip).
    val domains: List<CloudDomain> = emptyList(),
    // Every address you may send as here (username@ each pool domain, your mailboxes,
    // admin-granted info@/sales@). null on older payloads.
    @SerialName("from_addresses") val fromAddresses: List<String>? = null,
)

@Serializable
data class CloudLoginResponse(
    val user: CloudUser? = null,
    val token: String? = null,
    @SerialName("requires_2fa") val requiresTwoFactor: Boolean? = null,
    @SerialName("user_id") val userId: String? = null,
)

@Serializable
data class CloudAccountResponse(
    val account: CloudUser,
    val organizations: List<CloudOrg> = emptyList(),
    @SerialName("current_org_id") val currentOrgId: String? = null,
)

@Serializable
data class CloudConversation(
    val id: String,
    val subject: String? = null,
    val status: String,
    val snippet: String? = null,
    val read: Boolean = false,
    @SerialName("from_address") val fromAddress: String? = null,
    @SerialName("to_address") val toAddress: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("message_count") val messageCount: Int? = null,
    /** Generated one-line preview; null until the classifier has run (or when AI
     *  triage is off for the org), in which case the row shows [snippet]. */
    @SerialName("ai_summary_short") val aiSummaryShort: String? = null,
    /** Jev triage label slug (built-in or org custom) + priority score 0–4 (docs/Triage.md). */
    @SerialName("triage_label") val triageLabel: String? = null,
    @SerialName("triage_priority") val triagePriority: Double? = null,
    @SerialName("next_action_due_on") val nextActionDueOn: String? = null,
    /** Per viewer: this member ticked the thread off in Lore (docs/TODO.md 48.11). */
    @SerialName("lore_done") val loreDone: Boolean = false,
)

/** An org triage label (`GET orgs/:org_id/triage-labels`) — only what rows render. */
@Serializable
data class CloudTriageLabel(val slug: String, val name: String)
@Serializable
data class CloudTriageLabelsResponse(@SerialName("triage_labels") val triageLabels: List<CloudTriageLabel> = emptyList())

/** An org Space — the fields the local classifier's taxonomy needs. */
@Serializable
data class CloudSpace(
    val slug: String? = null,
    val name: String = "",
    val description: String? = null,
    @SerialName("not_for") val notFor: String? = null,
    val classify: Boolean = true,
)
@Serializable
data class CloudSpacesResponse(val spaces: List<CloudSpace> = emptyList())

@Serializable
data class CloudConversationsResponse(val conversations: List<CloudConversation> = emptyList())

@Serializable
data class CloudUnreadCountResponse(@SerialName("unread_count") val unreadCount: Int = 0)

@Serializable
data class CloudMessage(
    val id: String,
    @SerialName("conversation_id") val conversationId: String? = null,
    @SerialName("from_address") val fromAddress: String? = null,
    @SerialName("to_address") val toAddress: String? = null,
    @SerialName("cc_address") val ccAddress: String? = null,
    val subject: String? = null,
    @SerialName("body_plain") val bodyPlain: String? = null,
    @SerialName("body_html") val bodyHtml: String? = null,
    @SerialName("is_inbound") val isInbound: Boolean = true,
    @SerialName("is_draft") val isDraft: Boolean = false,
    @SerialName("created_at") val createdAt: String? = null,
    // Meeting invite (parsed VEVENT + rsvp_status); null on non-invite messages.
    val invite: ClientInvite? = null,
    @SerialName("meeting_request") val meetingRequest: com.inbox2.app.model.ClientMeetingRequest? = null,
    @SerialName("encryption_scheme") val encryptionScheme: String? = null,
) {
    /** Sealed, and nothing has opened it for this reader yet. */
    val isLocked get() = (encryptionScheme ?: "none") != "none" && bodyPlain == null && bodyHtml == null
}

@Serializable
data class CloudConversationDetail(
    val id: String,
    val subject: String? = null,
    val status: String,
    val messages: List<CloudMessage> = emptyList(),
    val tags: List<CloudTag> = emptyList(),
    val assignees: List<CloudMember> = emptyList(),
    val notes: List<CloudNote> = emptyList(),
)

@Serializable
data class CloudConversationDetailResponse(val conversation: CloudConversationDetail)

@Serializable
data class CloudMessageResponse(val message: CloudMessage)

// ── collaboration types (iOS CloudModels) ───────────────────────────────────

/** A team tag, or one of the viewer's own private labels (only they see it). */
@Serializable
data class CloudTag(val id: String, val name: String, val color: String? = null,
                    @SerialName("private") val isPrivate: Boolean = false)
@Serializable
data class CloudTagsResponse(val tags: List<CloudTag> = emptyList())
@Serializable
data class CloudTagResponse(val tag: CloudTag)

@Serializable
data class CloudPerson(
    val id: String? = null, val username: String? = null,
    val email: String? = null, val name: String? = null,
) {
    val label: String get() = listOfNotNull(name, username, email).firstOrNull { it.isNotEmpty() } ?: "?"
}

@Serializable
data class CloudMember(val id: String, val role: String? = null, val user: CloudPerson? = null)
@Serializable
data class CloudMembersResponse(val members: List<CloudMember> = emptyList())
@Serializable
data class CloudAssigneesResponse(val assignees: List<CloudMember> = emptyList())

@Serializable
data class CloudNote(
    val id: String, val body: String,
    @SerialName("created_at") val createdAt: String? = null,
    val author: CloudMember? = null,
)
@Serializable
data class CloudNoteResponse(val note: CloudNote)

@Serializable
data class CloudView(val id: String, val name: String, val kind: String, val icon: String? = null)
@Serializable
data class CloudViewsResponse(val views: List<CloudView> = emptyList())

@Serializable
data class CloudDraftsResponse(val drafts: List<CloudMessage> = emptyList())
@Serializable
data class CloudDraftResponse(val draft: CloudMessage)

@Serializable
data class CloudAttachment(val id: String, val key: String? = null) { val ref: String get() = key ?: id }
@Serializable
data class CloudAttachmentResponse(val attachment: CloudAttachment)

/** A domain thread with its messages + collaboration state (mapped for the reader). */
data class DomainThread(
    val messages: List<Message>,
    val tags: List<CloudTag>,
    val assignees: List<CloudMember>,
    val notes: List<CloudNote>,
    val sealedLocked: Boolean = false,
)

// ── Mapping domain (API) models → the shared row/reader models (iOS extensions) ──

fun CloudConversation.toConversation(orgId: String) = Conversation(
    id = id, accountKey = orgId,
    fromAddress = fromAddress ?: "", toAddress = toAddress ?: "",
    subject = subject ?: "", snippet = snippet ?: "",
    status = status, unread = !read,
    hasAttachment = false, priorityUrgent = false, priorityImportant = false, aiSummary = null,
    triageLabel = triageLabel, aiSummaryMedium = null, aiSummaryShort = aiSummaryShort,
    createdAt = createdAt ?: "", updatedAt = updatedAt ?: createdAt ?: "",
    messageCount = messageCount ?: 1, triagePriority = triagePriority, dueOn = nextActionDueOn, loreDone = loreDone,
)

fun CloudMessage.toMessage() = Message(
    id = id, fromAddress = fromAddress ?: "", toAddress = toAddress ?: "",
    ccAddress = ccAddress, subject = subject ?: "",
    bodyPlain = bodyPlain, bodyHTML = bodyHtml,
    isInbound = isInbound, isDraft = isDraft,
    createdAt = createdAt ?: "", sentimentLabel = null, intentLabel = null,
    invite = invite, meetingRequest = meetingRequest,
)

// Cloud-synced per-channel open-tracking config (docs/Open-Tracking.md).
@Serializable
data class CloudChannelTracking(
    @SerialName("email_address") val emailAddress: String,
    @SerialName("open_tracking_enabled") val openTrackingEnabled: Boolean = false,
    @SerialName("track_domain") val trackDomain: String? = null,
)

@Serializable
data class CloudChannelTrackingList(val channels: List<CloudChannelTracking> = emptyList())

// ── Zones: soft focus blocks on the user's calendar (never busy time) ───────

/** A zone category (`GET account/zone-categories`). `color` is always a palette key
 *  (blue/amber/violet/green/rose/teal) — the theme maps it (ThemePalette.zone). */
@Serializable
data class CloudZoneCategory(val id: String, val name: String, val color: String = "blue", val position: Int = 0) {
    companion object {
        /** ZoneCategory::COLORS — the only values the API takes. */
        val COLORS = listOf("blue", "amber", "violet", "green", "rose", "teal")
    }
}
@Serializable
data class CloudZoneCategoriesResponse(@SerialName("zone_categories") val zoneCategories: List<CloudZoneCategory> = emptyList())

@Serializable
data class CloudZone(
    val id: String,
    val name: String,
    val note: String? = null,
    @SerialName("category_id") val categoryId: String? = null,
    @SerialName("start_at") val startAt: String,
    @SerialName("end_at") val endAt: String,
    val notify: Boolean = true,
    /** The series' key — [id] is an occurrence id (`zon_x@20260925T140000Z`) for a
     *  repeating zone, so it (not this) keys alarms, dismissals and list identity. */
    @SerialName("series_id") val seriesId: String? = null,
    /** none | daily | weekdays | weekly (Zone::REPEATS). */
    val repeat: String = REPEAT_NONE,
    @SerialName("repeat_until") val repeatUntil: String? = null,
    @SerialName("time_zone") val timeZone: String? = null,
    /** A prep zone follows this calendar event: it ends when the event starts. */
    @SerialName("anchor_event_id") val anchorEventId: String? = null,
    @SerialName("anchor_minutes") val anchorMinutes: Int? = null,
    /** This occurrence's card was clicked away on some device (any device). */
    val dismissed: Boolean = false,
) {
    @kotlinx.serialization.Transient val startMs: Long = com.inbox2.app.model.RelativeTime.parse(startAt)?.time ?: 0L
    @kotlinx.serialization.Transient val endMs: Long = com.inbox2.app.model.RelativeTime.parse(endAt)?.time ?: 0L
    fun isActive(now: Long) = now in startMs until endMs
    val repeating: Boolean get() = repeat != REPEAT_NONE
    companion object {
        const val REPEAT_NONE = "none"
        /** Zone::REPEATS with their labels, in picker order. */
        val REPEATS = listOf(REPEAT_NONE to "Never", "daily" to "Every day", "weekdays" to "Every weekday", "weekly" to "Every week")
    }
}
@Serializable
data class CloudZonesResponse(val zones: List<CloudZone> = emptyList())
@Serializable
data class CloudZoneResponse(val zone: CloudZone)
@Serializable
data class CloudZoneCategoryResponse(@SerialName("zone_category") val zoneCategory: CloudZoneCategory)

/** A "not available" window (`blk_`, `/orgs/:id/blocked-times`, iOS CloudBlockedTime) —
 *  busy in every free/busy read but not a calendar event; only its owner sees it. */
@Serializable
data class CloudBlockedTime(
    val id: String,
    @SerialName("start_at") val startAt: String,
    @SerialName("end_at") val endAt: String,
) {
    val start: java.util.Date? get() = com.inbox2.app.model.RelativeTime.parse(startAt)
    val end: java.util.Date? get() = com.inbox2.app.model.RelativeTime.parse(endAt)
}
@Serializable data class CloudBlockedTimesResponse(@SerialName("blocked_times") val blockedTimes: List<CloudBlockedTime> = emptyList())
@Serializable data class CloudBlockedTimeResponse(@SerialName("blocked_time") val blockedTime: CloudBlockedTime)
