package com.inbox2.app.cloud

import com.inbox2.app.engine.EngineModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/**
 * Drives the engine's local mirror of MX mail (docs/MX-Sync.md) and serves reads
 * from it. The Android counterpart of iOS `MxMirror.swift`.
 *
 * The Rust engine does the syncing and replays queued actions; this tells it which
 * orgs to mirror and when to run a pass — sign-in, foreground, an FCM wake (mobile
 * has no realtime socket) — and clears the mirror on sign-out: mail must not outlive
 * the session on the device. [CloudSession] asks here first and falls back to the
 * API whenever the answer is null.
 */
class MxMirror(private val engine: EngineModel) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val json = Json { ignoreUnknownKeys = true }
    // watch / reset / kick state changes one at a time: a forget still in flight must
    // not land after the same org was re-watched.
    private val gate = Mutex()
    private var orgs = emptySet<String>()
    private var userKey: String? = null
    private val running = mutableSetOf<String>()

    // ── driving the engine ───────────────────────────────────────────────────

    /** The signed-in session changed: hand the engine the bearer, mirror exactly these
     *  orgs as this user, forget the rest. Idempotent. */
    fun watch(orgIds: List<String>, user: String, token: String?) = scope.launch {
        val fresh = gate.withLock {
            val want = orgIds.toSet()
            val switched = userKey != user
            engine.setCloudSession(token)
            (orgs - want).forEach { engine.mxForget(it) }
            val fresh = if (switched) want else want - orgs
            orgs = want; userKey = user
            fresh
        }
        fresh.forEach { kick(it) }
    }

    /** Foreground, or a push said something changed: a pass for every mirrored org. */
    fun kickAll() { orgs.forEach { kick(it) } }

    fun kick(org: String, directory: Boolean = false) = scope.launch {
        val user = gate.withLock {
            val u = userKey
            if (u == null || org !in orgs || !running.add(org)) null else u
        } ?: return@launch
        var dir = directory
        var changed = false
        try {
            // One kick's worth; the engine's own 60s beat carries on after.
            repeat(MAX_PASSES_PER_KICK) {
                val r = engine.mxSync(org, user, dir) ?: return@repeat
                dir = false
                if ((r.pulled + r.deleted + r.backfilled + r.hydrated + r.removed) > 0u) changed = true
                if (!r.more) return@launch
            }
        } finally {
            gate.withLock { running.remove(org) }
            if (changed) engine.mxChanged()
        }
    }

    /** Sign-out: every mirrored org — mail, queued actions, keys — leaves the device. */
    suspend fun unlockIdentity(password: String) = engine.mxUnlockIdentity(password)

    /** Hand every mirrored org its sealed domain keys. One unreachable org doesn't stop
     *  the others; the caller rechecks the thread it cares about. False if none worked. */
    suspend fun unlockSealed(identity: String): Boolean = orgs.map { engine.mxUnlockOrg(it, identity) }.any { it }

    fun reset() = scope.launch {
        gate.withLock {
            orgs.forEach { engine.mxForget(it) }
            orgs = emptySet(); userKey = null
            engine.setCloudSession(null)
        }
    }

    // ── reads (null → ask the API) ───────────────────────────────────────────

    /** Only what the mirror can evaluate: search, Sent (`direction`) and the assignee
     *  views are the server's, so callers never send those here. */
    suspend fun conversations(orgId: String, status: String?, read: Boolean?, domain: String?, page: Int = 1, labeledOnly: Boolean = false,
                              folder: String? = null, inboxFolders: Map<String, Set<String>> = emptyMap()): List<CloudConversation>? =
        local(orgId) { org -> json.decodeFromString<CloudConversationsResponse>(engine.store.mxConversationsJson(org, status, read, domain, page, perPage = if (labeledOnly) 50 else 200, labeledOnly = labeledOnly, folder = folder, inboxFolders = inboxFolders)).conversations }

    suspend fun conversationDetail(orgId: String, id: String): CloudConversationDetail? =
        local(orgId) { org -> engine.store.mxConversationDetailJson(org, id)?.let { json.decodeFromString<CloudConversationDetailResponse>(it).conversation } }

    suspend fun tags(orgId: String): List<CloudTag>? =
        local(orgId) { org -> json.decodeFromString<CloudTagsResponse>(engine.store.mxDirectoryJson(org, "tags")).tags }

    suspend fun members(orgId: String): List<CloudMember>? =
        local(orgId) { org -> json.decodeFromString<CloudMembersResponse>(engine.store.mxDirectoryJson(org, "members")).members }

    private suspend fun <T> local(orgId: String, read: (String) -> T?): T? = withContext(Dispatchers.IO) {
        val user = userKey ?: return@withContext null
        engine.store.reopenIfNeeded()
        val org = engine.store.mxOrg(orgId, user) ?: return@withContext null
        // A payload the models can't decode is a bug to log, not a reason to show an
        // empty inbox: fall back to the API.
        runCatching { read(org) }.onFailure { android.util.Log.e(TAG, "mirror read failed: ${it.message}") }.getOrNull()
    }

    // ── writes ───────────────────────────────────────────────────────────────

    /** archive / trash / spam / open / mark_read / mark_unread. In the mirror before
     *  this returns, queued durably, sent when the network allows — so it succeeds
     *  offline. False = this org isn't mirrored; the caller uses the API. */
    suspend fun perform(orgId: String, conversationIds: List<String>, action: String): Boolean {
        val user = userKey ?: return false
        val org = withContext(Dispatchers.IO) { engine.store.mxOrg(orgId, user, complete = false) } ?: return false
        return engine.mxAction(org, conversationIds, action)
    }

    private companion object {
        const val TAG = "com.inbox2.mxmirror"
        const val MAX_PASSES_PER_KICK = 25
    }
}
