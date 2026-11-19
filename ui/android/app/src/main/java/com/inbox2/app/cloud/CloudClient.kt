package com.inbox2.app.cloud

import com.inbox2.app.AppConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Bearer-token REST client for the inbox2 mx (domain/MX) pool — ported from iOS
 * CloudClient. No cookies/CSRF; the token is the only secret. Base URL = AppConfig
 * (`/api/v1`). Mirrors the iOS endpoint surface (login/account/conversations/detail/
 * bulk/update/send). Lives off the main thread.
 */
class CloudClient {
    private val json = Json { ignoreUnknownKeys = true }
    @Volatile private var token: String? = null
    fun setToken(t: String?) { token = t }

    private val base get() = AppConfig.apiBase

    suspend fun login(username: String, password: String, totp: String?): CloudLoginResponse {
        val body = JSONObject().put("username", username).put("password", password)
        if (totp != null) body.put("totp_code", totp)
        return decode(request("POST", "/auth/login", body.toString(), authed = false))
    }

    suspend fun account(): CloudAccountResponse = decode(request("GET", "/account", authed = true))

    suspend fun logout() { runCatching { request("POST", "/auth/logout", authed = true) } }

    // Open tracking: per-channel config sync (docs/Open-Tracking.md).
    suspend fun channelTracking(): List<CloudChannelTracking> =
        decode<CloudChannelTrackingList>(request("GET", "/tracking/channels", authed = true)).channels

    suspend fun setChannelTracking(email: String, enabled: Boolean, trackDomain: String?) {
        val body = JSONObject().put("email", email).put("open_tracking_enabled", enabled)
            .put("track_domain", trackDomain ?: "")
        request("PUT", "/tracking/channels", body.toString(), authed = true)
    }

    /** Register this device's FCM token so the API can push (docs/Cloud-Push.md "Mobile push"). */
    suspend fun registerPushDevice(fcmToken: String, deviceName: String?) {
        request("POST", "/push-devices",
            JSONObject().put("token", fcmToken).put("platform", "android")
                .put("device_name", deviceName ?: JSONObject.NULL).toString(),
            authed = true)
    }

    suspend fun deregisterPushDevice(fcmToken: String) {
        // Token in the query string: Android's HttpURLConnection rejects DELETE bodies.
        request("DELETE", "/push-devices?token=" + URLEncoder.encode(fcmToken, "UTF-8"), authed = true)
    }

    /** `labeled` narrows to threads with any label but resolved (custom ones too) before paging. */
    suspend fun conversations(orgId: String, status: String?, read: Boolean?, direction: String? = null, assignee: String? = null, search: String?, domain: String? = null, page: Int = 1, labeled: Boolean = false): List<CloudConversation> {
        if (!search.isNullOrBlank()) {
            val resp: CloudConversationsResponse = decode(request("GET", "/orgs/$orgId/search?q=${enc(search)}", authed = true))
            return resp.conversations
        }
        var path = "/orgs/$orgId/conversations?page=$page&per_page=50"
        if (status != null) path += "&status=$status"
        if (read != null) path += "&read=$read"
        if (direction != null) path += "&direction=$direction"
        if (assignee != null) path += "&assignee=$assignee"
        if (domain != null) path += "&domain=$domain"
        if (labeled) path += "&labeled=true"
        val resp: CloudConversationsResponse = decode(request("GET", path, authed = true))
        return resp.conversations
    }

    /** Combined domain-pool unread count for the org (mirrors iOS client.unreadCount). */
    suspend fun unreadCount(orgId: String): Int =
        decode<CloudUnreadCountResponse>(request("GET", "/orgs/$orgId/conversations/unread-count", authed = true)).unreadCount

    suspend fun conversationDetail(orgId: String, id: String): CloudConversationDetail {
        val resp: CloudConversationDetailResponse = decode(request("GET", "/orgs/$orgId/conversations/$id", authed = true))
        return resp.conversation
    }

    suspend fun drafts(orgId: String): List<CloudMessage> =
        decode<CloudDraftsResponse>(request("GET", "/orgs/$orgId/drafts", authed = true)).drafts
    suspend fun views(orgId: String): List<CloudView> =
        decode<CloudViewsResponse>(request("GET", "/orgs/$orgId/views", authed = true)).views
    suspend fun tags(orgId: String): List<CloudTag> =
        decode<CloudTagsResponse>(request("GET", "/orgs/$orgId/tags", authed = true)).tags
    suspend fun triageLabels(orgId: String): List<CloudTriageLabel> =
        decode<CloudTriageLabelsResponse>(request("GET", "/orgs/$orgId/triage-labels", authed = true)).triageLabels
    suspend fun spaces(orgId: String): List<CloudSpace> =
        decode<CloudSpacesResponse>(request("GET", "/orgs/$orgId/spaces", authed = true)).spaces
    suspend fun members(orgId: String): List<CloudMember> =
        decode<CloudMembersResponse>(request("GET", "/orgs/$orgId/members", authed = true)).members

    /** A private label: only the caller sees it, and any member may make one. */
    suspend fun createPrivateLabel(orgId: String, name: String): CloudTag =
        decode<CloudTagResponse>(request("POST", "/orgs/$orgId/tags",
            JSONObject().put("name", name).put("private", true).toString(), authed = true)).tag
    /** Replace a conversation's tags (the server keeps other members' private labels). */
    suspend fun setTags(orgId: String, conversationId: String, tagIds: List<String>) {
        request("PUT", "/orgs/$orgId/conversations/$conversationId/tags",
            JSONObject().put("tag_ids", JSONArray(tagIds)).toString(), authed = true)
    }
    suspend fun setAssignees(orgId: String, conversationId: String, memberIds: List<String>): List<CloudMember> =
        decode<CloudAssigneesResponse>(request("PUT", "/orgs/$orgId/conversations/$conversationId/assignees",
            JSONObject().put("member_ids", JSONArray(memberIds)).toString(), authed = true)).assignees
    suspend fun addNote(orgId: String, conversationId: String, body: String): CloudNote =
        decode<CloudNoteResponse>(request("POST", "/orgs/$orgId/conversations/$conversationId/notes",
            JSONObject().put("body", body).toString(), authed = true)).note

    suspend fun snooze(orgId: String, conversationId: String, untilISO: String) {
        request("POST", "/orgs/$orgId/conversations/$conversationId/snooze",
            JSONObject().put("until", untilISO).toString(), authed = true)
    }
    suspend fun unsnooze(orgId: String, conversationId: String) {
        request("DELETE", "/orgs/$orgId/conversations/$conversationId/snooze", authed = true)
    }
    suspend fun cancelSend(orgId: String, messageId: String) {
        request("POST", "/orgs/$orgId/messages/$messageId/cancel-send", authed = true)
    }
    /** RSVP to a meeting-invite message (`accepted`|`declined`|`tentative`). */
    suspend fun rsvp(orgId: String, messageId: String, status: String) {
        request("POST", "/orgs/$orgId/messages/$messageId/rsvp",
            JSONObject().put("status", status).toString(), authed = true)
    }
    /** Answer a meet-link booking request. Accept creates the event and mails the
     *  visitor an ICS invite; decline mails them a no (with [reason], if any). */
    suspend fun answerMeetingRequest(orgId: String, requestId: String, accept: Boolean, reason: String?) {
        request("POST", "/orgs/$orgId/meeting-requests/$requestId/${if (accept) "accept" else "decline"}",
            JSONObject().apply { if (!accept && reason != null) put("reason", reason) }.toString(), authed = true)
    }
    /** Put an emailed event (a PUBLISH .ics, which asks for no answer) onto the
     *  member's own calendar. No REPLY is sent — nobody asked for one. */
    suspend fun importCalendarEvent(orgId: String, messageId: String) {
        // A detected meeting's time is the sender's wall clock: the server reads it in our zone.
        request("POST", "/orgs/$orgId/messages/$messageId/calendar-import",
            JSONObject().put("time_zone", java.util.TimeZone.getDefault().id).toString(), authed = true)
    }
    suspend fun createDraft(orgId: String, from: String, to: String, cc: String?, subject: String?, bodyPlain: String, conversationId: String?): CloudMessage {
        val body = JSONObject().put("from_address", from).put("to_address", to).put("body_plain", bodyPlain)
        conversationId?.let { body.put("conversation_id", it) }
        cc?.takeIf { it.isNotEmpty() }?.let { body.put("cc_address", it) }
        subject?.let { body.put("subject", it) }
        return decode<CloudDraftResponse>(request("POST", "/orgs/$orgId/drafts", body.toString(), authed = true)).draft
    }
    suspend fun deleteDraft(orgId: String, draftId: String) {
        runCatching { request("DELETE", "/orgs/$orgId/drafts/$draftId", authed = true) }
    }
    suspend fun scheduleSend(orgId: String, draftId: String, sendAtISO: String) {
        request("POST", "/orgs/$orgId/messages/$draftId/schedule",
            JSONObject().put("send_at", sendAtISO).toString(), authed = true)
    }

    // ── Lore (docs/Ontology.md) + Disk pages (docs/plans/disk.md): raw JSON, parsed by the caller ──

    suspend fun loreEntities(orgId: String, kind: String, q: String): String =
        request("GET", "/orgs/$orgId/lore/entities?kind=${enc(kind)}&q=${enc(q)}", authed = true)
    suspend fun loreEntity(orgId: String, id: String): String =
        request("GET", "/orgs/$orgId/lore/entities/${enc(id)}", authed = true)
    /** `{ brand: { name, icon_url, theme_color } }` for a sender domain (docs/plans/lore.md §4b). */
    suspend fun brand(domain: String): String = request("GET", "/brands/${enc(domain)}", authed = true)
    suspend fun disk(orgId: String): String = request("GET", "/orgs/$orgId/disk", authed = true)
    suspend fun diskChildren(orgId: String, parentId: String, type: String?, cursor: String?): String =
        request("GET", "/orgs/$orgId/disk/nodes/${enc(parentId)}/children?sort=name&dir=asc" +
            (type?.let { "&type=$it" } ?: "") + (cursor?.let { "&cursor=${enc(it)}" } ?: ""), authed = true)
    suspend fun diskPage(orgId: String, id: String): String =
        request("GET", "/orgs/$orgId/disk/pages/${enc(id)}", authed = true)

    suspend fun bulk(orgId: String, conversationIds: List<String>, action: String) {
        val body = JSONObject()
            .put("conversation_ids", JSONArray(conversationIds))
            .put("action_name", action)
        request("POST", "/orgs/$orgId/conversations/bulk", body.toString(), authed = true)
    }

    suspend fun updateConversation(orgId: String, id: String, read: Boolean? = null, status: String? = null) {
        val body = JSONObject()
        if (read != null) body.put("read", read)
        if (status != null) body.put("status", status)
        request("PATCH", "/orgs/$orgId/conversations/$id", body.toString(), authed = true)
    }

    /** Send (new thread or reply); returns the created message id (for undo-send). */
    suspend fun send(orgId: String, conversationId: String?, from: String, to: String, cc: String?, subject: String?, bodyPlain: String, bodyHtml: String? = null, attachmentKeys: List<String> = emptyList()): String {
        val body = JSONObject().put("from_address", from).put("to_address", to).put("body_plain", bodyPlain)
        if (conversationId != null) body.put("conversation_id", conversationId)
        if (cc != null) body.put("cc_address", cc)
        if (subject != null) body.put("subject", subject)
        if (bodyHtml != null) { body.put("body_html", bodyHtml); body.put("content_type", "text/html") }
        if (attachmentKeys.isNotEmpty()) body.put("attachment_keys", JSONArray(attachmentKeys))
        val resp: CloudMessageResponse = decode(request("POST", "/orgs/$orgId/messages", body.toString(), authed = true))
        return resp.message.id
    }

    /** Multipart upload of a file against a (draft) message; returns the attachment key. */
    suspend fun uploadAttachment(orgId: String, messageId: String, filename: String, mimeType: String, data: ByteArray): String =
        withContext(Dispatchers.IO) {
            val boundary = "inbox2-$messageId-${data.size}"
            val c = (URL("$base/orgs/$orgId/attachments").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"; doOutput = true
                instanceFollowRedirects = false   // never replay the bearer across a redirect
                token?.let { setRequestProperty("Authorization", "Bearer $it") }
                setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            }
            c.outputStream.use { out ->
                fun w(s: String) = out.write(s.toByteArray())
                w("--$boundary\r\nContent-Disposition: form-data; name=\"message_id\"\r\n\r\n$messageId\r\n")
                w("--$boundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"$filename\"\r\nContent-Type: $mimeType\r\n\r\n")
                out.write(data); w("\r\n--$boundary--\r\n")
            }
            val ok = c.responseCode in 200..299
            val text = (if (ok) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            if (!ok) throw CloudException("attachment upload failed (${c.responseCode})")
            decode<CloudAttachmentResponse>(text).attachment.ref
        }

    // ── zones (user-scoped soft focus blocks; never busy time) ───────────────
    /** First call seeds the four defaults server-side (Deep work/Prep/Admin/Personal). */
    suspend fun zoneCategories(): List<CloudZoneCategory> =
        decode<CloudZoneCategoriesResponse>(request("GET", "/account/zone-categories", authed = true)).zoneCategories
    suspend fun zones(startISO: String, endISO: String): List<CloudZone> =
        decode<CloudZonesResponse>(request("GET", "/account/zones?start=${enc(startISO)}&end=${enc(endISO)}", authed = true)).zones
    /** Create ([id] null) or partially update a zone; [body] carries only the fields to set. */
    suspend fun saveZone(id: String?, body: JSONObject): CloudZone =
        decode<CloudZoneResponse>(request(if (id == null) "POST" else "PATCH",
            "/account/zones" + (id?.let { "/${enc(it)}" } ?: ""), body.toString(), authed = true)).zone
    suspend fun deleteZone(id: String) { request("DELETE", "/account/zones/${enc(id)}", authed = true) }

    // ── blocked time (org-scoped, the member's own; busy to everyone, an event to no one) ──
    suspend fun blockedTimes(orgId: String, startISO: String, endISO: String): List<CloudBlockedTime> =
        decode<CloudBlockedTimesResponse>(request("GET", "/orgs/${enc(orgId)}/blocked-times?start=${enc(startISO)}&end=${enc(endISO)}", authed = true)).blockedTimes
    suspend fun createBlockedTime(orgId: String, startISO: String, endISO: String): CloudBlockedTime =
        decode<CloudBlockedTimeResponse>(request("POST", "/orgs/${enc(orgId)}/blocked-times",
            JSONObject().put("start_at", startISO).put("end_at", endISO).toString(), authed = true)).blockedTime
    suspend fun deleteBlockedTime(orgId: String, id: String) { request("DELETE", "/orgs/${enc(orgId)}/blocked-times/${enc(id)}", authed = true) }
    /** Idempotent: records that this occurrence's card was clicked away, for every device. */
    suspend fun dismissZone(occurrenceId: String, endISO: String) {
        request("POST", "/account/zone-dismissals",
            JSONObject().put("occurrence_id", occurrenceId).put("end_at", endISO).toString(), authed = true)
    }
    suspend fun saveZoneCategory(id: String?, body: JSONObject): CloudZoneCategory =
        decode<CloudZoneCategoryResponse>(request(if (id == null) "POST" else "PATCH",
            "/account/zone-categories" + (id?.let { "/$it" } ?: ""), body.toString(), authed = true)).zoneCategory
    suspend fun deleteZoneCategory(id: String) { request("DELETE", "/account/zone-categories/$id", authed = true) }

    // ── transport ────────────────────────────────────────────────────────────
    private inline fun <reified T> decode(s: String): T = json.decodeFromString(s)
    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    private suspend fun request(method: String, path: String, jsonBody: String? = null, authed: Boolean): String =
        withContext(Dispatchers.IO) {
            val c = (URL(base + path).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                instanceFollowRedirects = false   // never replay the bearer across a redirect
                setRequestProperty("Accept", "application/json")
                if (authed) token?.let { setRequestProperty("Authorization", "Bearer $it") }
                if (jsonBody != null) {
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    outputStream.use { it.write(jsonBody.toByteArray()) }
                }
            }
            val ok = c.responseCode in 200..299
            val text = (if (ok) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            if (!ok) throw CloudException(errorMessage(text, c.responseCode))
            text
        }

    private fun errorMessage(body: String, code: Int): String = runCatching {
        val o = JSONObject(body)
        o.optString("error").ifEmpty { o.optString("message") }
            .ifEmpty { o.optJSONArray("errors")?.optJSONObject(0)?.optString("message").orEmpty() }
    }.getOrNull()?.ifEmpty { null } ?: "Request failed ($code)"
}

class CloudException(message: String) : Exception(message)
