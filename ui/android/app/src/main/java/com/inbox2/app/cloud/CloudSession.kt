package com.inbox2.app.cloud

import org.json.JSONObject
import android.content.Context
import com.inbox2.app.model.ConvStatusValue
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.MailFolder
import com.inbox2.app.model.Message
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** A file to attach to a domain (mx) send/schedule (iOS OutgoingAttachment). */
data class OutgoingAttachment(val filename: String, val mimeType: String, val data: ByteArray)

/**
 * inbox2 mx (domain/MX) session (iOS CloudSession). Holds auth state, the signed-in
 * user, orgs + active org, and exposes domain-mail helpers that map CloudConversation/
 * CloudMessage → the shared Conversation/Message so the existing rows/reader/compose
 * render domain mail unchanged. Folder→status and verb→bulk-action translations live
 * here. The token is the only secret — kept in `SecureStore` (EncryptedSharedPreferences
 * over an Android Keystore master key), the counterpart of the iOS Keychain.
 */
class CloudSession(context: Context) {
    private val appCtx = context.applicationContext
    private val client = CloudClient()
    /** The engine's local mirror of MX mail (docs/MX-Sync.md): asked first, the API
     *  second. Lazy — building the engine is not for the constructor. */
    private val mirror by lazy { MxMirror(com.inbox2.app.engine.EngineModel.get(appCtx)) }

    /** Point the mirror at this session's orgs (idempotent), and let it catch up. */
    private fun mirrorSession(token: String?) {
        val user = _user.value ?: return
        mirror.watch(_orgs.value.map { it.id }, user.id, token)
        mirror.kickAll()
    }

    private val _user = MutableStateFlow<CloudUser?>(null)
    val user: StateFlow<CloudUser?> = _user.asStateFlow()
    private val _orgs = MutableStateFlow<List<CloudOrg>>(emptyList())
    val orgs: StateFlow<List<CloudOrg>> = _orgs.asStateFlow()
    private val _activeOrg = MutableStateFlow<String?>(null)
    val activeOrg: StateFlow<String?> = _activeOrg.asStateFlow()

    /** Switch the active org (iOS CloudAccountPanel org picker). Ignores unknown ids. */
    fun setActiveOrg(id: String) {
        if (_orgs.value.any { it.id == id }) _activeOrg.value = id
    }

    val isSignedIn: Boolean get() = _user.value != null

    /** Validate the stored token against /account on launch; 401 → signed out.
     *  The keystore read is here (not in init) and on IO: SecureStore's first access
     *  builds the master key + decrypts the prefs file, too slow for the main thread. */
    /** True until the stored token has been checked at launch (iOS CloudSession.state == .loading). */
    val restoring = MutableStateFlow(true)

    suspend fun restore() {
        val token = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.inbox2.app.SecureStore.get(appCtx, com.inbox2.app.SecureStore.MX_TOKEN)
        } ?: run { restoring.value = false; return }
        client.setToken(token)
        runCatching {
            val acct = client.account()
            _user.value = acct.account
            _orgs.value = acct.organizations
            _activeOrg.value = acct.currentOrgId ?: acct.organizations.firstOrNull()?.id
            mirrorSession(token)
        }.onFailure { signOutLocal() }
        restoring.value = false
    }

    /** Re-pull /account while signed in so a domain added/removed elsewhere (console,
     *  another device) surfaces — mobile has no realtime channel, so this runs on
     *  foreground (MainActivity.onResume). Unlike restore(), it keeps the active org if
     *  it still exists and does NOT sign out on failure (a transient/offline blip must
     *  not drop the session). */
    suspend fun refreshAccount() {
        if (!isSignedIn) return
        runCatching {
            val acct = client.account()
            _user.value = acct.account
            _orgs.value = acct.organizations
            if (_activeOrg.value == null || _orgs.value.none { it.id == _activeOrg.value }) {
                _activeOrg.value = acct.currentOrgId ?: acct.organizations.firstOrNull()?.id
            }
            // Runs on every foreground: this is when the mirror catches up.
            mirrorSession(com.inbox2.app.SecureStore.get(appCtx, com.inbox2.app.SecureStore.MX_TOKEN))
        }
    }

    // Open tracking: per-channel config sync (docs/Open-Tracking.md).
    suspend fun channelTracking(): List<CloudChannelTracking> =
        runCatching { client.channelTracking() }.getOrDefault(emptyList())

    suspend fun saveChannelTracking(email: String, enabled: Boolean, trackDomain: String?) {
        runCatching { client.setChannelTracking(email, enabled, trackDomain) }
    }

    /** Returns null on success, "2fa" if a TOTP is required, else an error message. */
    suspend fun login(username: String, password: String, totp: String?): String? = runCatching {
        val resp = client.login(username, password, totp)
        if (resp.requiresTwoFactor == true && totp == null) return "2fa"
        val token = resp.token ?: return "Sign-in didn't finish. Try again."
        com.inbox2.app.SecureStore.set(appCtx, com.inbox2.app.SecureStore.MX_TOKEN, token)
        client.setToken(token)
        // A bearer exists now — complete any deferred push-device registration.
        com.inbox2.app.fcm.FcmTokenManager.ensureRegistered(appCtx)
        restore()
        null
    }.getOrElse { it.message ?: "Login failed" }

    /** Adopt a device-link minted `ink_` token as the account bearer — the token IS the
     *  bearer (GET /account resolves a Session OR an ApiKey), so storing it + populating
     *  via restore() signs the app in exactly like login. Returns null on success, else an
     *  error message. Triggers push-device registration the same way login does. */
    suspend fun adoptLinkedToken(token: String): String? = runCatching {
        com.inbox2.app.SecureStore.set(appCtx, com.inbox2.app.SecureStore.MX_TOKEN, token)
        client.setToken(token)
        // Validate + populate user/orgs; throws (and signs out locally) if the token is bad.
        val acct = client.account()
        _user.value = acct.account
        _orgs.value = acct.organizations
        _activeOrg.value = acct.currentOrgId ?: acct.organizations.firstOrNull()?.id
        // A bearer exists now — complete any deferred push-device registration.
        com.inbox2.app.fcm.FcmTokenManager.ensureRegistered(appCtx)
        mirrorSession(token)
        null
    }.getOrElse { signOutLocal(); it.message ?: "Linking failed" }

    suspend fun signOut() {
        runCatching { client.logout() }
        signOutLocal()
    }

    private fun signOutLocal() {
        mirror.reset() // the mirrored mail leaves the device with the session
        SealedKeys.delete(appCtx)
        com.inbox2.app.SecureStore.set(appCtx, com.inbox2.app.SecureStore.MX_TOKEN, null)
        // Forget the registered-token marker so the next sign-in re-registers the
        // device under the new account (the API moves the token on re-register).
        com.inbox2.app.fcm.FcmTokenManager.forget(appCtx)
        client.setToken(null)
        _user.value = null; _orgs.value = emptyList(); _activeOrg.value = null
        _folderTrees.value = emptyMap(); folderLoadedAt.clear()
        // Zones are the account's: drop them and disarm their alarms.
        _upcomingZones.value = emptyList(); _zoneCategories.value = emptyList()
        com.inbox2.app.notify.ZoneAlerts.reconcile(appCtx, emptyList(), emptyList())
    }

    // ── domain mail (mapped to shared models) ────────────────────────────────

    /** `domain` (a `dom_…` key) narrows the org pool to one workspace domain; null
     *  lists the whole org (the legacy single-domain chip). */
    /** `page` (1-based) pages both the mirror (its own page size) and the API (50 rows). */
    /** `addressFolder` lists one address folder (its key); without it the Inbox is
     *  "mail for you" (folder=inbox). Lore (`labeledOnly`) keeps the whole pool. */
    suspend fun conversations(orgId: String, folder: MailFolder, query: String, view: String = "All", domain: String? = null, page: Int = 1, labeledOnly: Boolean = false, addressFolder: String? = null): List<Conversation> {
        // Drafts come from the drafts endpoint; Sent uses direction=outbound.
        if (folder == MailFolder.DRAFTS) {
            return client.drafts(orgId).mapNotNull { m ->
                val convId = m.conversationId ?: return@mapNotNull null
                Conversation(convId, orgId, m.fromAddress ?: "", m.toAddress ?: "", m.subject ?: "(No subject)",
                    (m.bodyPlain ?: "").take(140), com.inbox2.app.model.ConvStatusValue.OPEN, false,
                    false, false, false, null, null, null, null, m.createdAt ?: "", m.createdAt ?: "", 1)
            }
        }
        val direction = if (folder == MailFolder.SENT) "outbound" else null
        val (assignee, read) = when (view) {
            "Mine" -> "me" to null
            "Unassigned" -> "none" to null
            "Unread" -> null to false
            else -> null to null
        }
        // The local mirror answers what it can evaluate — instantly, and offline.
        // Search, Sent (direction) and the assignee views are the server's.
        val addr = when {
            labeledOnly -> null
            addressFolder != null -> addressFolder
            folder == MailFolder.INBOX -> CloudAddressFolder.INBOX
            else -> null
        }
        if (query.isBlank() && direction == null && assignee == null) {
            // Any folder read keeps the trees (drawer counts) fresh; only Inbox filters by them.
            val inboxKeys = if (addr != null) inboxFolderKeys(orgId, domain) else emptyMap()
            mirror.conversations(orgId, folderStatus(folder), read, domain, page, labeledOnly, addr, inboxKeys)?.let { rows -> return rows.map { it.toConversation(orgId) } }
        }
        // Lore (labeledOnly): the server keeps any label but resolved, before paging.
        return client.conversations(orgId, folderStatus(folder), read, direction, assignee, query.ifBlank { null }, domain, page, labeledOnly, addr)
            .map { it.toConversation(orgId) }
    }

    // ── address folders (per MX domain: Inbox, Yours, Shared, Other) ─────────

    private val _folderTrees = MutableStateFlow<Map<String, List<CloudAddressFolder>>>(emptyMap())
    /** Domain key (`dom_…`) → its folder tree, in display order. */
    val folderTrees: StateFlow<Map<String, List<CloudAddressFolder>>> = _folderTrees.asStateFlow()
    private val folderLoadedAt = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val bg = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)

    /** Fetch one domain's tree now. Failures keep what was loaded. */
    suspend fun loadFolders(orgId: String, domain: String) {
        runCatching { client.folders(orgId, domain) }.onSuccess { tree ->
            folderLoadedAt[domain] = System.currentTimeMillis()
            _folderTrees.value = _folderTrees.value + (domain to tree)
        }
    }

    /** Domain → keys of its folders shown in the Inbox, for the mirror's Inbox filter.
     *  A missing tree is fetched (briefly awaited, so offline stays instant); a loaded
     *  one refreshes in the background. */
    // ponytail: 15 s throttle per domain, a push-driven refresh if unread counts lag.
    private suspend fun inboxFolderKeys(orgId: String, domain: String?): Map<String, Set<String>> {
        val domains = domain?.let { listOf(it) } ?: _orgs.value.firstOrNull { it.id == orgId }?.domains?.map { it.id }.orEmpty()
        val now = System.currentTimeMillis()
        domains.forEach { d ->
            val at = folderLoadedAt[d]
            if (at == null) kotlinx.coroutines.withTimeoutOrNull(1500) { loadFolders(orgId, d) }
            else if (now - at > 15_000) { folderLoadedAt[d] = now; bg.launch { loadFolders(orgId, d) } }
        }
        val trees = _folderTrees.value
        return domains.mapNotNull { d -> trees[d]?.let { t -> d to t.filter { it.inInbox }.mapTo(HashSet()) { it.key } } }.toMap()
    }

    /** Bell / Show in Inbox: flip it here at once, save, then reload the tree (Show in
     *  Inbox changes what the Inbox counts) and the lists. */
    suspend fun setFolderPref(orgId: String, domain: String, folder: CloudAddressFolder, inbox: Boolean? = null, notify: Boolean? = null) {
        val address = folder.prefKey ?: return
        _folderTrees.value[domain]?.let { tree ->
            _folderTrees.value = _folderTrees.value + (domain to tree.map {
                if (it.key != folder.key) it else it.copy(inInbox = inbox ?: it.inInbox, notify = notify ?: it.notify)
            })
        }
        runCatching { client.setFolderPrefs(orgId, address, inbox, notify) }
            .onFailure { android.util.Log.w("com.inbox2.folders", "Saving the setting failed: ${it.message}") }
        loadFolders(orgId, domain)
        bump()
    }

    /** Combined domain-pool unread count for the org — one of the two numbers the
     *  OS badge sums; the unified inbox header reuses it. Failures count as 0. */
    suspend fun unreadCount(orgId: String): Int = runCatching { client.unreadCount(orgId) }.getOrDefault(0)

    private suspend fun detail(orgId: String, conversationId: String): CloudConversationDetail =
        mirror.conversationDetail(orgId, conversationId) ?: client.conversationDetail(orgId, conversationId)

    suspend fun messages(orgId: String, conversationId: String): List<Message> =
        detail(orgId, conversationId).messages.map { it.toMessage() }

    /** Full domain thread + collaboration state (tags/assignees/notes) for the reader. */
    suspend fun unlockIdentity(password: String) = mirror.unlockIdentity(password)
    suspend fun unlockSealed(identity: String): Boolean = mirror.unlockSealed(identity)

    /** Reloads the reader, which removes the unlock bar: call last, its scope dies with it. */
    fun sealedChanged() = bump()

    suspend fun thread(orgId: String, conversationId: String): DomainThread {
        val d = detail(orgId, conversationId)
        return DomainThread(d.messages.map { it.toMessage() }, d.tags, d.assignees, d.notes, d.messages.any { it.isLocked })
    }

    suspend fun perform(orgId: String, conversationIds: List<String>, verb: String) {
        // Mirrored org: the engine applies it locally, queues it and sends it — so it
        // works offline. Otherwise straight to the API.
        if (!mirror.perform(orgId, conversationIds, bulkAction(verb))) client.bulk(orgId, conversationIds, bulkAction(verb))
        bump()
    }

    /** RSVP to a meeting-invite message; true on success (docs/Meeting-Invites.md). */
    suspend fun rsvp(orgId: String, messageId: String, status: String): Boolean =
        runCatching { client.rsvp(orgId, messageId, status); bump(); true }.getOrDefault(false)

    /** Accept/decline a meet-link booking request. Null on success, else the reason. */
    suspend fun answerMeetingRequest(orgId: String, requestId: String, accept: Boolean, reason: String?): String? =
        runCatching { client.answerMeetingRequest(orgId, requestId, accept, reason); bump(); null }
            .getOrElse { it.message ?: "Couldn't send your answer." }

    /** MX counterpart of the engine's `addInviteToCalendar`: file an emailed event on
     *  the member's calendar. Returns success. */
    suspend fun importCalendarEvent(orgId: String, messageId: String): Boolean =
        runCatching { client.importCalendarEvent(orgId, messageId); bump(); true }.getOrDefault(false)

    suspend fun send(orgId: String, conversationId: String?, from: String, to: String, cc: String?, subject: String?, body: String, attachments: List<OutgoingAttachment> = emptyList()) {
        val messageId = if (attachments.isEmpty()) {
            client.send(orgId, conversationId, from, to, cc, subject, body)
        } else {
            // Attachments need a message to upload against: create a draft, upload to it,
            // send threaded to the draft's conversation, then drop the draft (iOS parity).
            val draft = client.createDraft(orgId, from, to, cc, subject, body, conversationId)
            val keys = attachments.map { client.uploadAttachment(orgId, draft.id, it.filename, it.mimeType, it.data) }
            val id = client.send(orgId, conversationId ?: draft.conversationId, from, to, cc, subject, body, attachmentKeys = keys)
            client.deleteDraft(orgId, draft.id)
            id
        }
        lastSent = SentRef(orgId, messageId); bump()
    }

    // ── zones ────────────────────────────────────────────────────────────────
    private val _zoneCategories = MutableStateFlow<List<CloudZoneCategory>>(emptyList())
    val zoneCategories: StateFlow<List<CloudZoneCategory>> = _zoneCategories.asStateFlow()
    /** Zones from yesterday through two weeks out — what the alarms and the in-app
     *  "in the zone" card work from. The calendar fetches its own window. */
    private val _upcomingZones = MutableStateFlow<List<CloudZone>>(emptyList())
    val upcomingZones: StateFlow<List<CloudZone>> = _upcomingZones.asStateFlow()
    private val _zoneRevision = MutableStateFlow(0)
    /** Bumped after any zone mutation so the calendar re-fetches its window. */
    val zoneRevision: StateFlow<Int> = _zoneRevision.asStateFlow()

    suspend fun zonesBetween(fromMs: Long, toMs: Long): List<CloudZone> =
        runCatching { client.zones(iso(fromMs), iso(toMs)) }.getOrDefault(emptyList())

    /** Re-pull categories + the upcoming window and re-arm the zone alarms. Runs on
     *  sign-in/app start and after every zone mutation. Failures keep what was loaded. */
    // ── blocked time (iOS BlockedTimeStore): the member's own "not available" windows
    //    on the active org — busy to everyone, an event to no one.
    suspend fun blockedTimes(startISO: String, endISO: String): List<CloudBlockedTime> {
        val org = _activeOrg.value ?: return emptyList()
        return runCatching { client.blockedTimes(org, startISO, endISO) }.getOrDefault(emptyList())
    }
    suspend fun createBlockedTime(startISO: String, endISO: String): CloudBlockedTime? {
        val org = _activeOrg.value ?: return null
        return runCatching { client.createBlockedTime(org, startISO, endISO) }.onSuccess { bump() }.getOrNull()
    }
    suspend fun deleteBlockedTime(id: String): Boolean {
        val org = _activeOrg.value ?: return false
        return runCatching { client.deleteBlockedTime(org, id); bump(); true }.getOrDefault(false)
    }

    suspend fun refreshZones() {
        if (!isSignedIn) return
        // Done taps whose POST didn't land yet (offline, killed receiver) retry here.
        com.inbox2.app.notify.ZoneAlerts.flushDismissals(appCtx, client)
        runCatching { _zoneCategories.value = client.zoneCategories() }
        val now = System.currentTimeMillis()
        runCatching { client.zones(iso(now - 86_400_000), iso(now + 14 * 86_400_000L)) }.onSuccess {
            _upcomingZones.value = it
            com.inbox2.app.notify.ZoneAlerts.reconcile(appCtx, it, _zoneCategories.value)
        }
    }

    /** Create ([id] null) or update a zone. On a repeating zone [id] is the occurrence
     *  id: the server shifts the whole series by the same delta. Null on success, else
     *  the reason. */
    suspend fun saveZone(
        id: String?, name: String, note: String?, categoryId: String?, startMs: Long, endMs: Long, notify: Boolean,
        repeat: String = CloudZone.REPEAT_NONE, repeatUntil: String? = null,
        anchorEventId: String? = null, anchorMinutes: Int? = null,
        /** Unhook a prep zone from its meeting (hand-retimed) — iOS clearAnchor. */
        clearAnchor: Boolean = false,
    ): String? =
        runCatching {
            val nul = JSONObject.NULL
            val body = JSONObject().put("name", name).put("note", note ?: nul)
                .put("category_id", categoryId ?: nul)
                .put("start_at", iso(startMs)).put("end_at", iso(endMs)).put("notify", notify)
                .put("repeat", repeat).put("repeat_until", repeatUntil ?: nul)
            // Repeats expand in the creator's zone, so 09:00 stays 09:00 across DST.
            if (id == null) body.put("time_zone", java.time.ZoneId.systemDefault().id)
            if (anchorEventId != null) body.put("anchor_event_id", anchorEventId).put("anchor_minutes", anchorMinutes)
            else if (clearAnchor) body.put("anchor_event_id", nul).put("anchor_minutes", nul)
            client.saveZone(id, body)
            // An edit un-dismisses the zone server-side (it alerts again); match that locally.
            if (id != null) com.inbox2.app.notify.ZoneAlerts.forgetSeries(appCtx, id.substringBefore('@'))
            zonesChanged(); null
        }.getOrElse { it.message ?: "Couldn't save the zone." }

    /** Deletes the zone — the whole series for a repeating one. */
    suspend fun deleteZone(id: String): String? =
        runCatching { client.deleteZone(id); zonesChanged(); null }.getOrElse { it.message ?: "Couldn't delete the zone." }

    /** Prep zones follow their meeting: an anchored zone whose loaded, live event now
     *  starts at a different time moves to end at the new start. A zone whose event
     *  isn't loaded is left alone (it may just be outside the window). */
    suspend fun reconcileAnchoredZones(zones: List<CloudZone>, events: List<com.inbox2.app.model.CalendarEvent>) {
        // Timed events only; a repeating zone is never anchored, and sub-minute drift isn't a move (iOS).
        val starts = events.filter { !it.allDay }.mapNotNull { e -> e.start?.let { e.id to it.time } }.toMap()
        var moved = false
        zones.filter { it.anchorEventId != null && it.anchorMinutes != null && !it.repeating }.distinctBy { it.seriesId ?: it.id }.forEach { z ->
            val start = starts[z.anchorEventId] ?: return@forEach
            if (kotlin.math.abs(start - z.endMs) < 60_000) return@forEach
            val body = JSONObject().put("start_at", iso(start - z.anchorMinutes!! * 60_000L)).put("end_at", iso(start))
            if (runCatching { client.saveZone(z.id, body) }.isSuccess) {
                com.inbox2.app.notify.ZoneAlerts.forgetSeries(appCtx, z.seriesId ?: z.id.substringBefore('@'))
                moved = true
            }
        }
        if (moved) zonesChanged()
    }

    // ── zone categories ─────────────────────────────────────────────────────
    /** Create ([id] null) or rename/recolour a category. Null on success, else the reason. */
    suspend fun saveZoneCategory(id: String?, name: String, color: String): String? =
        runCatching {
            client.saveZoneCategory(id, JSONObject().put("name", name).put("color", color))
            _zoneCategories.value = client.zoneCategories(); null
        }.getOrElse { it.message ?: "Couldn't save the category." }

    /** Its zones stay, uncategorised — so the zone lists re-fetch too. */
    suspend fun deleteZoneCategory(id: String): String? =
        runCatching { client.deleteZoneCategory(id); zonesChanged(); null }.getOrElse { it.message ?: "Couldn't delete the category." }

    /** Also the FCM `zones_changed` path while the UI is up (RootTabs). */
    suspend fun zonesChanged() { _zoneRevision.value += 1; refreshZones() }

    private fun iso(ms: Long): String = java.time.format.DateTimeFormatter.ISO_OFFSET_DATE_TIME
        .format(java.time.Instant.ofEpochMilli(ms).atZone(java.time.ZoneId.systemDefault()))

    // ── collaboration passthroughs ───────────────────────────────────────────
    suspend fun tags(orgId: String) = mirror.tags(orgId) ?: runCatching { client.tags(orgId) }.getOrDefault(emptyList())
    suspend fun spaces(orgId: String) = runCatching { client.spaces(orgId) }.getOrNull()

    /** Load every org's triage label names into [com.inbox2.app.engine.TriageLabelNames]
     *  so MX rows can name custom labels. Failures keep what was loaded. */
    suspend fun loadTriageLabelNames() {
        val loaded = _orgs.value.mapNotNull { o ->
            runCatching { o.id to client.triageLabels(o.id).associate { it.slug to it.name } }.getOrNull()
        }
        com.inbox2.app.engine.TriageLabelNames.org = com.inbox2.app.engine.TriageLabelNames.org + loaded
    }
    suspend fun members(orgId: String) = mirror.members(orgId) ?: runCatching { client.members(orgId) }.getOrDefault(emptyList())
    suspend fun views(orgId: String) = runCatching { client.views(orgId) }.getOrDefault(emptyList())
    suspend fun drafts(orgId: String) = runCatching { client.drafts(orgId) }.getOrDefault(emptyList())
    suspend fun setTags(orgId: String, conversationId: String, tagIds: List<String>) { runCatching { client.setTags(orgId, conversationId, tagIds); bump() } }
    /** A private label for the signed-in member; null on failure (a taken or priority name). */
    suspend fun createPrivateLabel(orgId: String, name: String): CloudTag? = runCatching { client.createPrivateLabel(orgId, name) }.getOrNull()
    suspend fun setAssignees(orgId: String, conversationId: String, memberIds: List<String>) { runCatching { client.setAssignees(orgId, conversationId, memberIds); bump() } }
    suspend fun addNote(orgId: String, conversationId: String, body: String) { runCatching { client.addNote(orgId, conversationId, body); bump() } }
    suspend fun snooze(orgId: String, conversationId: String, untilISO: String) { runCatching { client.snooze(orgId, conversationId, untilISO); bump() } }
    suspend fun scheduleSend(orgId: String, draftId: String, sendAtISO: String) { runCatching { client.scheduleSend(orgId, draftId, sendAtISO); bump() } }

    /** Compose-and-schedule: create a draft (with any attachments) then schedule it for `sendAtISO`. */
    suspend fun scheduleNewSend(orgId: String, conversationId: String?, from: String, to: String, cc: String?, subject: String?, body: String, sendAtISO: String, attachments: List<OutgoingAttachment> = emptyList()): Boolean =
        runCatching {
            val d = client.createDraft(orgId, from, to, cc, subject, body, conversationId)
            attachments.forEach { client.uploadAttachment(orgId, d.id, it.filename, it.mimeType, it.data) }
            client.scheduleSend(orgId, d.id, sendAtISO); bump(); true
        }.getOrDefault(false)

    /** Undo the last domain send within the window (server reverts it to a draft). */
    suspend fun undoLastSend(): Boolean {
        val s = lastSent ?: return false
        return runCatching { client.cancelSend(s.orgId, s.messageId); lastSent = null; bump(); true }.getOrDefault(false)
    }

    private data class SentRef(val orgId: String, val messageId: String)
    @Volatile private var lastSent: SentRef? = null
    private fun bump() { _revision.value = _revision.value + 1 }
    private val _revision = MutableStateFlow(0)
    /** Bumped after any domain mutation so views re-query (iOS CloudSession.revision). */
    val revision: StateFlow<Int> = _revision.asStateFlow()

    /** Re-query the domain lists on return to foreground: a delete/read on another
     *  device leaves no local mutation to bump us, so the list would stay stale. */
    fun refreshViews() = bump()

    /** Folder → API status filter (iOS CloudSession). */
    private fun folderStatus(folder: MailFolder): String? = when (folder) {
        MailFolder.ARCHIVE -> "archived"
        MailFolder.TRASH -> "trash"
        else -> null   // inbox/open
    }

    companion object {
        /** Engine verb → cloud bulk action (org/MX threads map the restore verbs to open). */
        fun bulkAction(verb: String): String = when (verb) {
            "archive" -> "archive"
            "trash" -> "trash"
            "spam" -> "spam"
            "mark_read" -> "mark_read"
            "mark_unread" -> "mark_unread"
            "unarchive", "untrash", "unspam" -> "open"
            else -> verb
        }
    }

    // ── Lore (docs/plans/lore.md): mined facts per MX org + the person's C:\Lore pages ──

    /** Facts the server-side miner learned about one entity, from every org. */
    suspend fun loreFacts(kind: String, domain: String?, address: String?): List<com.inbox2.app.engine.LoreFact> {
        val q = (if (kind == "organization") domain else address) ?: return emptyList()
        return orgs.value.flatMap { org ->
            runCatching {
                val id = com.inbox2.app.engine.LoreFact.matchId(client.loreEntities(org.id, kind, q), kind, domain, address)
                    ?: return@runCatching emptyList()
                com.inbox2.app.engine.LoreFact.facts(client.loreEntity(org.id, id))
            }.getOrElse { android.util.Log.w("CloudSession", "lore facts ${org.id}: ${it.message}"); emptyList() }
        }
    }

    /** The pages in C:\Lore (C:\ is the same disk from every team, so the first org whose
     *  Disk answers and lists reaches it). Read-only here: no folder or page is created.
     *  An org whose listing fails is logged and the next one tried; null when none works. */
    suspend fun lorePages(): Pair<String, List<com.inbox2.app.engine.LorePageRef>>? {
        for (org in orgs.value) {
            val drives = runCatching { JSONObject(client.disk(org.id)) }.getOrNull() ?: continue
            // Read-only (a downgraded team) still lists and reads pages; only an off Disk is skipped.
            val diskState = drives.optJSONObject("settings")?.optString("state", "active") ?: "active"
            if (diskState != "active" && diskState != "read_only") continue
            val root = drives.optJSONObject("c_drive")?.optString("id") ?: continue
            val found = runCatching {
                // Sealed nodes come back with a null name: skip them (and anything nameless).
                fun named(n: JSONObject) = !n.isNull("name") && n.optString("name").isNotEmpty()
                val folder = children(org.id, root, null).filter(::named).firstOrNull {
                    it.optString("name") == "Lore" && it.optString("kind", "folder").ifEmpty { "folder" } == "folder"
                } ?: return@runCatching org.id to emptyList()
                org.id to children(org.id, folder.optString("id"), "pages")
                    .filter { named(it) && it.optString("kind") == "page" }
                    .map { com.inbox2.app.engine.LorePageRef(it.optString("id"), it.optString("name")) }
            }.onFailure { android.util.Log.w("CloudSession", "lore pages ${org.id}: ${it.message}") }.getOrNull()
            if (found != null) return found
        }
        return null
    }

    /** Every child of a Disk folder (the listing is cursor-paged). */
    private suspend fun children(orgId: String, parentId: String, type: String?): List<JSONObject> {
        val out = mutableListOf<JSONObject>()
        var cursor: String? = null
        do {
            val page = JSONObject(client.diskChildren(orgId, parentId, type, cursor))
            page.optJSONArray("nodes")?.let { a -> (0 until a.length()).forEach { out += a.getJSONObject(it) } }
            cursor = page.optString("next_cursor").takeIf { !page.isNull("next_cursor") && it.isNotEmpty() }
        } while (cursor != null)
        return out
    }

    /** The brand lookup's icon, as the original remote URL (its `icon_url` is an image-proxy
     *  path carrying it as `url`); null when the domain has none. Only the domain leaves. */
    suspend fun brandIconUrl(domain: String): String? = runCatching {
        val icon = JSONObject(client.brand(domain)).optJSONObject("brand")
            ?.takeUnless { it.isNull("icon_url") }?.optString("icon_url")?.ifEmpty { null } ?: return@runCatching null
        android.net.Uri.parse(icon).getQueryParameter("url")
    }.getOrNull()

    /** A Lore page's markdown (throws on failure — the reader shows it). */
    suspend fun lorePageMarkdown(orgId: String, id: String): String =
        JSONObject(client.diskPage(orgId, id)).optJSONObject("page")
            ?.takeUnless { it.isNull("markdown") }?.optString("markdown").orEmpty()
}
