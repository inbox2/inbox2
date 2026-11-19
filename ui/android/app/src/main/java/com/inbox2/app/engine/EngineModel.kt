package com.inbox2.app.engine

import android.content.Context
import android.util.Log
import com.inbox2.app.AppConfig
import com.inbox2.app.data.InboxStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import uniffi.inbox2_core.EngineEventListener
import uniffi.inbox2_core.FfiAttachment
import uniffi.inbox2_core.FfiBridgeAction
import uniffi.inbox2_core.FfiBridgeConfig
import uniffi.inbox2_core.FfiBridgeReply
import uniffi.inbox2_core.FfiDeviceProfile
import uniffi.inbox2_core.FfiException
import uniffi.inbox2_core.FfiLaneInfo
import uniffi.inbox2_core.FfiPromptSection
import uniffi.inbox2_core.InboxEngine

/**
 * Owns the shared Rust [InboxEngine] and surfaces its state to Compose. Mirrors the iOS
 * EngineModel: the engine opens the local SQLite store, runs poll + write-back loops,
 * boots connected accounts, and pushes events to [EngineListener]. The UI reads mail
 * directly from [store]; mutations go through these suspend helpers (off the main
 * thread). State changes bump [dataVersion]; Compose re-queries on it. See iOS-App.md §3.
 */
class EngineModel(context: Context) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _status = MutableStateFlow("starting…")
    val status: StateFlow<String> = _status.asStateFlow()

    private val _accounts = MutableStateFlow<List<AccountRow>>(emptyList())
    val accounts: StateFlow<List<AccountRow>> = _accounts.asStateFlow()

    /** Bumped on every data-changing engine event (sync / new-message / calendar). */
    private val _dataVersion = MutableStateFlow(0)
    val dataVersion: StateFlow<Int> = _dataVersion.asStateFlow()

    /** Conversation keys the user just removed (archive/trash/spam/snooze) that the
     *  store may still return until the durable write-back commits. List reloads
     *  filter these out so a just-filed row can't flicker back in, then drop keys the
     *  store no longer returns (reconciled). Shared so the reader path (which doesn't
     *  touch the list) can suppress too. Mirrors iOS InboxListView.pendingRemoved. */
    private val _pendingRemoved = MutableStateFlow<Set<String>>(emptySet())
    val pendingRemoved: StateFlow<Set<String>> = _pendingRemoved.asStateFlow()
    fun markRemoved(keys: Collection<String>) {
        if (keys.isNotEmpty()) _pendingRemoved.value = _pendingRemoved.value + keys
    }
    fun unmarkRemoved(keys: Collection<String>) {
        if (keys.isNotEmpty()) _pendingRemoved.value = _pendingRemoved.value - keys.toSet()
    }

    private val _syncing = MutableStateFlow(false)
    val syncing: StateFlow<Boolean> = _syncing.asStateFlow()

    /** Live model-download state keyed by id, fed by `model-download` events. */
    private val _modelDownloads = MutableStateFlow<Map<String, ModelDownload>>(emptyMap())
    val modelDownloads: StateFlow<Map<String, ModelDownload>> = _modelDownloads.asStateFlow()

    /** One triage result landing (`triage-updated`): the row's new label + one-line
     *  summary. Screens patch the matching row in place instead of re-querying the
     *  store — the event fires once per labeled thread, which during a catch-up
     *  drain is continuous; a full requery + recompose per event made the whole
     *  app sluggish. `seq` keeps consecutive patches distinct for LaunchedEffect. */
    data class TriagePatch(val key: String, val label: String?, val summaryShort: String?, val seq: Int, val priority: Double? = null)
    private val _triagePatch = MutableStateFlow<TriagePatch?>(null)
    val triagePatch: StateFlow<TriagePatch?> = _triagePatch.asStateFlow()
    private var triagePatchSeq = 0

    /** Async triage/summary progress, fed by `triage-progress` events. */
    private val _triage = MutableStateFlow(TriageState.EMPTY)
    val triage: StateFlow<TriageState> = _triage.asStateFlow()

    /** The selected processing window (`1_month` … `everything`). */
    private val _processingWindow = MutableStateFlow(ProcessingWindow.DEFAULT.raw)
    val processingWindow: StateFlow<String> = _processingWindow.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    val dataDir: File = File(appContext.filesDir, "inbox2").apply { mkdirs() }
    val store = InboxStore(File(dataDir, "inbox2.db").path)

    private var engine: InboxEngine? = null
    private var newMessageSink: ((String) -> Unit)? = null

    fun setNewMessageSink(sink: (String) -> Unit) { newMessageSink = sink }

    init { start() }

    private fun start() {
        val listener = object : EngineEventListener {
            override fun onEvent(event: String, payloadJson: String) {
                Log.d(TAG, "event=$event payloadLen=${payloadJson.length}")
                if (event in DATA_CHANGING) scheduleDataBump()
                if (event == "sync" && _syncing.value) scheduleSyncStop(1500)
                if (event == "new-message") newMessageSink?.invoke(payloadJson)
                if (event == "model-download") {
                    ModelDownload.fromJson(payloadJson)?.let { d ->
                        _modelDownloads.value = _modelDownloads.value + (d.id to d)
                    }
                }
                // Progress ticks update the bar only (high frequency); a triage-updated
                // means a conversation's label/summaries changed → re-query for badges.
                if (event == "triage-progress") {
                    TriageState.fromJson(payloadJson)?.let { _triage.value = it }
                }
                if (event == "triage-updated") {
                    runCatching {
                        val o = JSONObject(payloadJson)
                        val key = o.optString("conversationKey", "")
                        if (key.isNotEmpty()) {
                            _triagePatch.value = TriagePatch(
                                key,
                                o.optString("label").takeIf { it.isNotEmpty() },
                                o.optString("summaryShort").takeIf { it.isNotEmpty() },
                                ++triagePatchSeq,
                                if (o.isNull("priority")) null else o.optDouble("priority"),
                            )
                        }
                    }
                }
            }
        }
        runCatching {
            // On-device NLU callback: routes the core's on-device generation to LiteRT
            // (Qwen) when present, else reports unavailable so the core falls back to
            // OpenAI — the same contract as iOS BridgeLLM.
            val llm = BridgeLLM(appContext) { this }
            bridgeLlm = llm
            val e = InboxEngine(dataDir.path, listener, llm, AppConfig.apiBase)
            engine = e
            // Search: the FTS5 MATCH runs in the core (Android's SQLite has no fts5 module).
            store.ftsKeys = { match, limit ->
                val arr = org.json.JSONArray(e.ftsConversationKeysJson(match, limit.toUInt()))
                (0 until arr.length()).map { arr.getString(it) }
            }
            _status.value = "running"
            Log.i(TAG, "engine started; data dir ${dataDir.path}")
            pushDeviceProfile(e)
            // Re-install the persisted prompt overrides (dev-mode editor). The core
            // holds overrides in memory only, so each launch re-applies the file;
            // invalid content is logged and skipped — never fatal.
            promptsFile.takeIf { it.exists() }?.readText()?.let { text ->
                runCatching { e.setPromptOverrides(text) }
                    .onFailure { Log.e(TAG, "prompt overrides rejected at launch: ${it.message}") }
            }
            refreshAccounts()
            loadTriageState(e)
            refreshTriageLabelNames()
        }.onFailure {
            _status.value = "error: ${it.message}"
            Log.e(TAG, "engine start failed: ${it.message}", it)
        }
    }

    private fun pushDeviceProfile(e: InboxEngine) {
        // Android has no native on-device LLM lane; android_native_speech reports whether
        // a SpeechRecognizer is present (drives the native STT lane availability).
        val hasSpeech = android.speech.SpeechRecognizer.isRecognitionAvailable(appContext)
        runCatching {
            e.setDeviceProfile(
                FfiDeviceProfile(
                    os = "android",
                    osMajor = android.os.Build.VERSION.SDK_INT.toUInt(),
                    osMinor = 0u,
                    appleIntelligence = false,
                    androidNativeSpeech = hasSpeech,
                )
            )
        }
    }

    fun refreshAccounts() {
        val e = engine ?: return
        // Off the caller's thread: listAccountsJson serializes on the engine's store
        // mutex, so while the sync/triage workers are writing it can wait on them —
        // callers include the engine's own event callback, which must never block.
        scope.launch(Dispatchers.IO) {
            runCatching { _accounts.value = AccountRow.parse(e.listAccountsJson()) }
                .onFailure { Log.e(TAG, "listAccounts failed: ${it.message}") }
        }
    }

    // ── Data-changing event coalescing (mirrors iOS scheduleDataBump) ───────
    // A sync burst emits many events back-to-back; each bump makes every visible
    // screen re-query SQLite and recompose. Fire immediately when the last bump
    // is old enough, else arm one trailing bump so the tail is never dropped.
    private var lastDataBump = 0L
    private var dataBumpJob: Job? = null
    private fun scheduleDataBump() {
        val since = System.currentTimeMillis() - lastDataBump
        if (since >= DATA_BUMP_MS) { applyDataBump(); return }
        if (dataBumpJob?.isActive == true) return
        dataBumpJob = scope.launch {
            delay(DATA_BUMP_MS - since)
            applyDataBump()
        }
    }
    private fun applyDataBump() {
        lastDataBump = System.currentTimeMillis()
        store.reopenIfNeeded()
        store.invalidateContactsCache()
        bump()
        refreshAccounts()
    }

    // ── Writes (suspend; run off-main) ──────────────────────────────────────

    private suspend fun <T> io(block: (InboxEngine) -> T): T? = withContext(Dispatchers.IO) {
        val e = engine ?: return@withContext null
        runCatching { block(e) }.getOrElse {
            Log.e(TAG, "ffi call failed: ${it.message}")
            null
        }
    }

    private fun bump() { _dataVersion.value = _dataVersion.value + 1 }

    /** Public data-version bump (e.g. after a local draft change) to re-query views. */
    fun bumpDataVersion() = bump()

    suspend fun perform(accountKey: String, conversationKeys: List<String>, action: String): Boolean {
        val ok = io { it.performAction(accountKey, conversationKeys, action); true } ?: false
        if (ok) bump()
        return ok
    }

    /** Route a conversation action by account key: a `dom_…`/`org_…` team-pool key goes
     *  to the cloud API, anything else to the local engine. The single home for the
     *  cloud-vs-engine branch previously copy-pasted across inbox/reader/bulk/undo. */
    suspend fun performRouted(
        cloud: com.inbox2.app.cloud.CloudSession,
        accountKey: String, conversationKeys: List<String>, verb: String,
    ): Boolean =
        if (com.inbox2.app.model.AccountKey.isDomain(accountKey))
            runCatching { cloud.perform(accountKey, conversationKeys, verb) }.isSuccess
        else perform(accountKey, conversationKeys, verb)

    suspend fun send(
        accountKey: String, from: String, to: String, cc: String?, bcc: String?,
        subject: String?, bodyPlain: String, attachments: List<FfiAttachment>,
        replyToMessageKey: String? = null,
    ): Pair<Boolean, String> {
        val result = io { e ->
            val json = e.sendMessage(accountKey, from, to, cc, bcc, subject, null, bodyPlain, attachments, replyToMessageKey)
            val status = runCatching { JSONObject(json).optString("status", "queued") }.getOrDefault("queued")
            (status != "failed") to status
        } ?: (false to "the app is still starting")
        bump()
        return result
    }

    /** Run [query] through each Gmail/Outlook account's own search (live; reads inside
     *  attachments) and return the local conversation keys it hit. An account that
     *  fails (offline, quota) adds nothing. */
    suspend fun providerSearch(accountKey: String?, query: String): List<String> {
        val searchable = com.inbox2.app.oauth.OAuthProvider.entries.map { it.providerType }.toSet()
        val keys = accounts.value.filter { it.provider in searchable && (accountKey == null || it.id == accountKey) }.map { it.id }
        return coroutineScope {
            keys.map { key ->
                async {
                    io { e ->
                        runCatching {
                            val arr = org.json.JSONArray(e.providerSearchJson(key, query))
                            (0 until arr.length()).map { arr.getString(it) }
                        }.onFailure { Log.w(TAG, "providerSearch $key failed: ${it.message}") }.getOrNull()
                    }.orEmpty()
                }
            }.awaitAll().flatten()
        }
    }

    suspend fun fetchMessage(accountKey: String, messageKey: String): FetchedMessage {
        return io { e ->
            val obj = JSONObject(e.fetchMessage(accountKey, messageKey))
            val atts = obj.optJSONArray("attachments")?.let { arr ->
                (0 until arr.length()).mapNotNull { i ->
                    val a = arr.optJSONObject(i) ?: return@mapNotNull null
                    val id = a.optString("attachment_id").ifEmpty { return@mapNotNull null }
                    val name = a.optString("filename").ifEmpty { return@mapNotNull null }
                    com.inbox2.app.model.AttachmentInfo(
                        id, name, a.optString("mime_type", "application/octet-stream"), a.optInt("size", 0)
                    )
                }
            } ?: emptyList()
            FetchedMessage(obj.optString("body_html").ifEmpty { null }, obj.optString("body_plain").ifEmpty { null }, atts)
        } ?: FetchedMessage(null, null, emptyList())
    }

    // ── Meeting invites (docs/Meeting-Invites.md) ───────────────────────────

    /** Detect + parse a local-channel message's text/calendar attachment into a
     *  ClientInvite, or null when it isn't an invite. The card gates this on already
     *  seeing a calendar attachment (one live fetch). */
    suspend fun inviteFor(accountKey: String, messageKey: String, attachmentId: String): com.inbox2.app.model.ClientInvite? =
        io { e ->
            e.inviteForAttachment(accountKey, messageKey, attachmentId)
                ?.let { json.decodeFromString<com.inbox2.app.model.ClientInvite>(it) }
        }

    /** RSVP to a local-channel invite (`accepted`|`declined`|`tentative`); the core
     *  writes back to the calendar API or an emailed METHOD:REPLY. */
    /** Add an emailed ICS event to the account's calendar (Google/Microsoft API, the
     *  account's primary writable calendar). Success carries the local event key —
     *  empty means added but the resync hasn't landed the row yet. A failure carries
     *  the engine's own message, which the banner shows as-is: a guessed reason would
     *  send the user looking in the wrong place.
     *
     *  The device zone is passed for *floating* ICS times only; a zoned ICS keeps its
     *  own zone, so the hour can't drift. */
    suspend fun addInviteToCalendar(accountKey: String, messageKey: String, attachmentId: String): Result<String> =
        withContext(Dispatchers.IO) {
            val e = engine ?: return@withContext Result.failure(IllegalStateException("The engine isn't running."))
            runCatching {
                e.addInviteToCalendar(accountKey, messageKey, attachmentId, null, java.util.TimeZone.getDefault().id)
            }.onFailure { Log.e(TAG, "addInviteToCalendar failed: ${it.message}") }
        }

    /** The meeting triage read out of a message body with no ICS attached, shaped as
     *  an invite (`detected`). Local SQLite only. */
    suspend fun detectedInvite(accountKey: String, messageKey: String): com.inbox2.app.model.ClientInvite? =
        io { e -> e.detectedInvite(accountKey, messageKey)?.let { json.decodeFromString<com.inbox2.app.model.ClientInvite>(it) } }

    /** "Add to calendar" for a detected meeting; its floating time is read in the device zone. */
    suspend fun addDetectedMeetingToCalendar(accountKey: String, messageKey: String): Result<String> =
        withContext(Dispatchers.IO) {
            val e = engine ?: return@withContext Result.failure(IllegalStateException("The engine isn't running."))
            runCatching {
                e.addDetectedMeetingToCalendar(accountKey, messageKey, null, java.util.TimeZone.getDefault().id)
            }.onFailure { Log.e(TAG, "addDetectedMeetingToCalendar failed: ${it.message}") }
        }

    suspend fun respondToInvite(accountKey: String, messageKey: String, attachmentId: String, response: String): Boolean {
        val ok = io { it.respondToInvite(accountKey, messageKey, attachmentId, response); true } ?: false
        if (ok) bump()
        return ok
    }

    /** In-memory LRU of attachment bytes (files can be large — keep only a few). */
    private val attachmentMemCache = object : LinkedHashMap<String, ByteArray>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: Map.Entry<String, ByteArray>) = size > 12
    }
    private val attachmentCacheDir by lazy { File(appContext.cacheDir, "attachment-cache").apply { mkdirs() } }

    /**
     * Download an attachment's bytes, cached so Open / Forward / Save reuse the
     * same file instead of re-fetching it. Two layers: an in-memory LRU for the
     * session, and an on-disk copy (keyed by account:message:attachment) that
     * survives app restart.
     */
    suspend fun downloadAttachment(accountKey: String, messageKey: String, attachmentId: String): ByteArray? {
        val key = "$accountKey:$messageKey:$attachmentId"
        synchronized(attachmentMemCache) { attachmentMemCache[key] }?.let { return it }

        val diskFile = File(attachmentCacheDir, key.replace(Regex("[^A-Za-z0-9_.-]"), "_"))
        val fromDisk = withContext(Dispatchers.IO) { if (diskFile.exists()) diskFile.readBytes() else null }
        if (fromDisk != null && fromDisk.isNotEmpty()) {
            synchronized(attachmentMemCache) { attachmentMemCache[key] = fromDisk }
            return fromDisk
        }

        val bytes = io { it.downloadAttachment(accountKey, messageKey, attachmentId) } ?: return null
        synchronized(attachmentMemCache) { attachmentMemCache[key] = bytes }
        withContext(Dispatchers.IO) { runCatching { diskFile.writeBytes(bytes) } } // persist for next session
        return bytes
    }

    suspend fun addAccount(
        providerType: String, email: String, displayName: String, authMethod: String,
        accessToken: String? = null, refreshToken: String? = null, password: String? = null,
        host: String? = null, port: UShort? = null, useTls: Boolean? = null,
        smtpHost: String? = null, smtpPort: UShort? = null, smtpUseTls: Boolean? = null,
        cloudBackup: Boolean? = null,
    ): Pair<Boolean, String> {
        val r = io { e ->
            true to e.addAccount(providerType, email, displayName, authMethod, accessToken, refreshToken,
                password, host, port, useTls, smtpHost, smtpPort, smtpUseTls, cloudBackup)
        } ?: (false to "the app is still starting")
        if (r.first) { store.reopenIfNeeded(); refreshAccounts(); bump() }
        return r
    }

    /** Add a Meta BYOK account (Instagram/Messenger/WhatsApp). App secret + System
     *  User token stay encrypted on-device; connect (token validation + webhook
     *  subscription + relay registration) runs in the background. See docs/Cloud-Push.md (Meta). */
    suspend fun addMetaAccount(
        channel: String, displayName: String?, appId: String, appSecret: String, systemUserToken: String,
        facebookPageId: String? = null, instagramAccountId: String? = null,
        whatsappPhoneNumberId: String? = null, whatsappBusinessAccountId: String? = null,
        reuseCredentialsFrom: String? = null,
        cloudBackup: Boolean? = null,
    ): Pair<Boolean, String> {
        val r = io { e ->
            true to e.addMetaAccount(channel, displayName, appId, appSecret, systemUserToken,
                facebookPageId, instagramAccountId, whatsappPhoneNumberId, whatsappBusinessAccountId,
                reuseCredentialsFrom, cloudBackup)
        } ?: (false to "the app is still starting")
        if (r.first) { store.reopenIfNeeded(); refreshAccounts(); bump() }
        return r
    }

    // ── Credential vault (zero-knowledge cloud backup — see docs/E2EE.md) ──

    /** Enable cloud backup with the inbox2 password; returns (ok, vaultId-or-error). */
    suspend fun enableCloudBackup(password: String): Pair<Boolean, String> =
        (io { true to it.enableCloudBackup(password) } ?: (false to "the app is still starting"))
            .also { if (it.first) bump() }

    /** Unlock the vault on this device with the inbox2 password. */
    suspend fun unlockVault(password: String): Boolean =
        io { it.unlockVault(password); true } ?: false

    /** Re-encrypt all backed-up credentials under a new password (after a change). */
    suspend fun rotateVault(newPassword: String): Boolean =
        io { it.rotateVault(newPassword); true } ?: false

    /** Restore all cloud-backed credentials with the inbox2 password; returns count. */
    suspend fun restoreFromCloud(password: String): Pair<Boolean, UInt> {
        val r = io { true to it.restoreFromCloud(password) } ?: (false to 0u)
        if (r.first) { store.reopenIfNeeded(); refreshAccounts(); bump() }
        return r
    }

    /** Drop the vault session (DEK + local state) on sign-out / account switch. */
    fun clearVaultSession() { engine?.clearVaultSession() }

    /** `{ enabled, unlocked, account_count }` JSON, or null if unavailable. */
    fun vaultStatusJson(): String? = runCatching { engine?.vaultStatusJson() }.getOrNull()

    /** Ingest a buffered Meta webhook event (silent `meta_event` push): fetch the raw
     *  payload, verify the HMAC against the local app_secret, normalize, apply.
     *  Returns whether anything was applied. See docs/Cloud-Push.md (Meta). */
    suspend fun ingestMetaEvent(eventKey: String): Boolean {
        val applied = io { it.ingestMetaEvent(eventKey) } ?: false
        if (applied) { store.reopenIfNeeded(); bump() }
        return applied
    }

    // ── MX mirror verbs (docs/MX-Sync.md; driven by cloud/MxMirror.kt) ────────

    /** The signed-in inbox2 session (null on sign-out) — the engine has no bearer
     *  on mobile otherwise, and mirrors nothing without one. */
    suspend fun setCloudSession(token: String?) { io { it.setCloudSession(AppConfig.apiBase, token) } }

    /** One bounded pass; null when the engine isn't up or the pass failed. */
    suspend fun mxSync(org: String, userKey: String, directory: Boolean): uniffi.inbox2_core.FfiMxReport? {
        val report = io { it.mxSync(org, userKey, directory, directory) }
        if (report != null) store.reopenIfNeeded()
        return report
    }

    /** True once it is in the mirror and queued (it is sent when the network allows). */
    suspend fun mxAction(org: String, threads: List<String>, action: String): Boolean {
        val ok = io { it.mxAction(org, threads, action); true } ?: false
        if (ok) bump()
        return ok
    }

    suspend fun mxForget(org: String) { io { it.mxForget(org) } }

    /** Null: no answer (offline). `key` null: a wrong password. */
    data class IdentityUnlock(val key: String?)
    suspend fun mxUnlockIdentity(password: String): IdentityUnlock? = io { IdentityUnlock(it.mxUnlockIdentity(password)) }
    suspend fun mxUnlockOrg(org: String, identityKey: String): Boolean = io { it.mxUnlockOrg(org, identityKey) } != null

    /** A push wake in a cold process: queued actions go out and every mirrored org
     *  gets a pass — the engine knows which orgs, no session object needed. */
    suspend fun mxTick() { io { it.mxTick() }; store.reopenIfNeeded(); bump() }

    /** The mirror moved: refresh whatever is on screen. */
    fun mxChanged() = bump()

    suspend fun removeAccount(accountKey: String): Boolean {
        val ok = io { it.removeAccount(accountKey); true } ?: false
        if (ok) { store.reopenIfNeeded(); refreshAccounts(); bump() }
        return ok
    }

    suspend fun retryOutbox(accountKey: String, outboxKey: String): Boolean {
        val ok = io { it.retryOutbox(accountKey, outboxKey); true } ?: false
        if (ok) bump(); return ok
    }

    suspend fun deleteOutbox(accountKey: String, outboxKey: String): Boolean {
        val ok = io { it.deleteOutbox(accountKey, outboxKey) } ?: false
        if (ok) bump(); return ok
    }

    // ── Lore todos (email-less; `lore_todos` in the core) ───────────────────

    /** Open Lore todos (manual + voice `add_reminder`), oldest first. */
    suspend fun loreTodos(): List<LoreTodo> = io { e ->
        val arr = JSONArray(e.loreListTodosJson())
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            LoreTodo(o.getString("id"), o.getString("title"), o.optString("source", "manual"))
        }
    } ?: emptyList()

    /** What the on-device ontology learned about an organization (by domain) or a person
     *  (by address) — exact match, like the web's `useLoreFacts`. */
    suspend fun loreFacts(kind: String, domain: String?, address: String?): List<LoreFact> = io { e ->
        val id = LoreFact.matchId(e.loreEntitiesJson(kind, if (kind == "organization") domain else address), kind, domain, address)
            ?: return@io emptyList()
        e.loreEntityJson(id)?.let { LoreFact.facts(it) } ?: emptyList()
    } ?: emptyList()

    /** Add a todo from the "+ Add todo" row. */
    suspend fun addLoreTodo(title: String): Boolean {
        val ok = io { it.loreAddTodo(title); true } ?: false
        if (ok) bump(); return ok
    }

    /** Tick a todo off (sets `done_at`). */
    /** A Send-to call (docs/MCP-Client.md): off the main thread, failures surface to the sheet. */
    suspend fun <T> mcp(block: (InboxEngine) -> T): T = withContext(Dispatchers.IO) {
        val e = engine ?: error("The app is still starting.")
        block(e)
    }

    suspend fun completeLoreTodo(id: String) {
        io { it.loreCompleteTodo(id) }
        bump()
    }

    suspend fun setRuleEnabled(ruleKey: String, enabled: Boolean): Boolean {
        val ok = io { it.setRuleEnabled(ruleKey, enabled) } ?: false
        if (ok) bump(); return ok
    }

    // ── Open tracking (docs/Open-Tracking.md) ───────────────────────────────

    /** Per-channel open-tracking opt-in + custom host (null = inbox2 default). */
    suspend fun setOpenTracking(accountKey: String, enabled: Boolean, trackDomain: String?): Boolean {
        val ok = io { it.setOpenTracking(accountKey, enabled, trackDomain?.ifBlank { null }); true } ?: false
        if (ok) bump(); return ok
    }

    /** Current settings for a channel; defaults to disabled/no-host on any error. */
    fun openTrackingSettings(accountKey: String): OpenTrackingSettings =
        runCatching { OpenTrackingSettings.parse(engine?.openTrackingSettingsJson(accountKey)) }
            .getOrDefault(OpenTrackingSettings(false, null))

    /** Open history (who/when/where) for a sent message, via its embedded token. */
    fun messageOpens(messageKey: String): List<MessageOpen> =
        runCatching { MessageOpen.parse(engine?.messageOpensJson(messageKey)) }.getOrDefault(emptyList())

    /** Mirror the user's cloud-synced per-channel open-tracking config into the local
     *  engine (matched to connected accounts by email), so pixel injection honors
     *  settings saved on their other devices. Suspends on a network call — call it
     *  off a launch coroutine so it never blocks startup (docs/Open-Tracking.md). */
    suspend fun mirrorChannelTracking(cloud: com.inbox2.app.cloud.CloudSession) {
        if (!cloud.isSignedIn) return
        val channels = cloud.channelTracking()
        if (channels.isEmpty()) return
        val byEmail = accounts.value.associateBy({ it.email.lowercase() }, { it.id })
        for (ch in channels) {
            val key = byEmail[ch.emailAddress.lowercase()] ?: continue
            setOpenTracking(key, ch.openTrackingEnabled, ch.trackDomain)
        }
    }

    suspend fun createBuiltinRule(name: String, conditionsJSON: String, actionJSON: String, accountKey: String?, enabled: Boolean): Pair<Boolean, String> {
        val r = io { true to it.createBuiltinRule(name, conditionsJSON, actionJSON, accountKey, enabled) } ?: (false to "")
        if (r.first) bump(); return r
    }

    suspend fun updateBuiltinRule(ruleKey: String, name: String, conditionsJSON: String, actionJSON: String): Boolean {
        val ok = io { it.updateBuiltinRule(ruleKey, name, conditionsJSON, actionJSON) } ?: false
        if (ok) bump(); return ok
    }

    suspend fun deleteRule(ruleKey: String): Boolean {
        val ok = io { it.deleteRule(ruleKey) } ?: false
        if (ok) bump(); return ok
    }

    /**
     * Create an event on a provider calendar. Returns (ok, provider id) or
     * (false, why). Not routed through [io]: that reports every failure as a
     * null, and what the provider said — "read-only calendar", "end before
     * start" — is the only thing that explains an event that didn't appear.
     */
    suspend fun createCalendarEvent(accountKey: String, calendarProviderId: String, draftJSON: String): Pair<Boolean, String> =
        withContext(Dispatchers.IO) {
            val e = engine ?: return@withContext false to "the app is still starting"
            runCatching { e.createCalendarEvent(accountKey, calendarProviderId, draftJSON) }
                .fold(
                    onSuccess = { id -> bump(); true to id },
                    onFailure = { err ->
                        Log.e(TAG, "createCalendarEvent failed: ${err.message}")
                        false to (err.message ?: err.toString())
                    },
                )
        }

    /** Update an event. Returns (ok, "") or (false, why) — the provider's reason, like
     *  [createCalendarEvent], not a bare "Update failed". */
    /** The rule of the series a synced instance belongs to, read off the provider
     *  (synced rows are expanded instances): success(null) for a one-off, failure when
     *  it couldn't be read — the sheet must not then treat a series as a one-off. */
    suspend fun calendarSeriesRule(accountKey: String, eventKey: String): Result<String?> =
        withContext(Dispatchers.IO) {
            val e = engine ?: return@withContext Result.failure(IllegalStateException("the app is still starting"))
            runCatching { e.calendarSeriesRule(accountKey, eventKey) }
                .onFailure { Log.e(TAG, "calendarSeriesRule failed: ${it.message}") }
        }

    suspend fun updateCalendarEvent(accountKey: String, eventKey: String, draftJSON: String): Pair<Boolean, String> =
        withContext(Dispatchers.IO) {
            val e = engine ?: return@withContext false to "the app is still starting"
            runCatching { e.updateCalendarEvent(accountKey, eventKey, draftJSON) }
                .fold(
                    onSuccess = { bump(); true to "" },
                    onFailure = { err ->
                        Log.e(TAG, "updateCalendarEvent failed: ${err.message}")
                        false to (err.message ?: err.toString())
                    },
                )
        }

    suspend fun deleteCalendarEvent(accountKey: String, eventKey: String): Boolean {
        val ok = io { it.deleteCalendarEvent(accountKey, eventKey); true } ?: false
        if (ok) bump(); return ok
    }

    /** Someone else's meeting on this account's calendar — deleting it offers to
     *  decline to the organizer first (iOS EngineModel.isInvite). */
    fun isInvite(event: com.inbox2.app.model.CalendarEvent): Boolean {
        val organizer = event.organizerEmail?.lowercase()?.takeIf { it.isNotEmpty() } ?: return false
        return organizer != accounts.value.firstOrNull { it.id == event.accountKey }?.email?.lowercase()
    }

    /** Delete, optionally declining first so the organizer hears about it — the delete
     *  alone tells nobody. A failed decline stops before the delete. Returns null on
     *  success, else the provider's reason. */
    suspend fun deleteCalendarEvent(event: com.inbox2.app.model.CalendarEvent, decline: Boolean): String? =
        withContext(Dispatchers.IO) {
            val e = engine ?: return@withContext "the app is still starting"
            runCatching {
                if (decline) e.respondToEvent(event.accountKey, event.id, "declined")
                e.deleteCalendarEvent(event.accountKey, event.id)
            }.fold(
                onSuccess = { bump(); null },
                onFailure = { err ->
                    Log.e(TAG, "deleteCalendarEvent failed: ${err.message}")
                    err.message ?: err.toString()
                },
            )
        }

    suspend fun respondToEvent(accountKey: String, eventKey: String, response: String): Boolean {
        val ok = io { it.respondToEvent(accountKey, eventKey, response); true } ?: false
        if (ok) bump(); return ok
    }

    // ── Bridge ──────────────────────────────────────────────────────────────

    suspend fun bridgeBrief(config: FfiBridgeConfig): FfiBridgeReply? = io { it.bridgeBrief(config) }
    suspend fun bridgeTomorrow(config: FfiBridgeConfig): FfiBridgeReply? = io { it.bridgeTomorrow(config) }
    suspend fun bridgeWeekHighlights(config: FfiBridgeConfig): FfiBridgeReply? = io { it.bridgeWeekHighlights(config) }
    suspend fun bridgeReply(config: FfiBridgeConfig, transcript: String): FfiBridgeReply? = io { it.bridgeReply(config, transcript) }
    suspend fun bridgeAgentTurn(config: FfiBridgeConfig, transcript: String): FfiBridgeReply? = io { it.bridgeAgentTurn(config, transcript) }

    /** Interpret a voice command into a confidence-scored action (speak / clarify / draft
     *  email / draft meeting); reversible inbox actions are run inside the core. The host
     *  opens draft sheets on screen — it never sends/saves (iOS EngineModel.bridgeCommand). */
    suspend fun bridgeCommand(config: FfiBridgeConfig, transcript: String): FfiBridgeAction? = io { it.bridgeCommand(config, transcript) }

    /** Abandon the multi-turn command dialog (a "cancel" barge-in) — iOS bridgeResetDialog. */
    fun bridgeResetDialog() { runCatching { engine?.bridgeResetDialog() } }
    /** Spoken read-out of one thread (previous-message context + latest summary). */
    suspend fun bridgeEmailVoice(config: FfiBridgeConfig, conversationKey: String): FfiBridgeReply? = io { it.bridgeEmailVoice(config, conversationKey) }

    /** Re-run one thread's label + summaries through a chosen engine (the reader's "Process
     *  with"). Writes the result to the store with its `triage_source` tag and returns that
     *  source; null on failure (iOS EngineModel.reprocessConversation). */
    suspend fun reprocessConversation(config: FfiBridgeConfig, conversationKey: String): String? =
        io { it.reprocessConversation(config, conversationKey) }

    /** null = valid; else the OpenAI error message. */
    suspend fun bridgeValidateOpenAI(key: String): String? = withContext(Dispatchers.IO) {
        val e = engine ?: return@withContext "Still starting up. Try again in a moment."
        try { e.bridgeValidateOpenai(key); null }
        catch (ex: FfiException) { ex.message ?: "Invalid key" }
        catch (ex: Exception) { ex.message }
    }

    suspend fun bridgeOpenAITTS(key: String, text: String, voice: String): ByteArray? = io { it.bridgeOpenaiTts(key, text, voice) }
    suspend fun bridgeOpenAITranscribe(key: String, audio: ByteArray): String? = io { it.bridgeOpenaiTranscribe(key, audio) }

    // ── Async triage + multi-level summaries ────────────────────────────────

    /** Read the window + progress snapshot at start; live updates arrive via events. */
    private fun loadTriageState(e: InboxEngine) {
        runCatching { e.getProcessingWindow() }.getOrNull()?.let { _processingWindow.value = it }
        runCatching { e.triageProgress() }.getOrNull()?.let { TriageState.fromJson(it)?.let { t -> _triage.value = t } }
    }

    // ── Jev (TypeSafe) triage — docs/Triage.md "Local channels" ──

    /** Push the stored Jev key (or null to clear) to the engine. Pushing a key — even
     *  the same one — clears an `unauthorized` status and retries. */
    suspend fun setJevKey(key: String?) = withContext(Dispatchers.IO) {
        val e = engine ?: return@withContext
        runCatching { e.setJevKey(key?.trim()?.ifEmpty { null }) }
        loadTriageState(e)
    }

    /** null = valid; else a user-displayable message from the core. */
    suspend fun validateJevKey(key: String): String? = withContext(Dispatchers.IO) {
        val e = engine ?: return@withContext "Still starting up. Try again in a moment."
        try { e.validateJevKey(key.trim()); null }
        catch (ex: FfiException) { ex.message ?: "Invalid key" }
        catch (ex: Exception) { ex.message }
    }

    /** The engine's triage labels (built-ins + custom), position order. */
    fun triageLabels(): List<TriageLabelDef> =
        runCatching { engine?.getTriageLabels() }.getOrNull()?.let { TriageLabelDef.parseList(it) } ?: emptyList()

    /** Replace the label list. Returns the stored list, or the core's validation message. */
    suspend fun saveTriageLabels(labels: List<TriageLabelDef>): Result<List<TriageLabelDef>> = withContext(Dispatchers.IO) {
        val e = engine ?: return@withContext Result.failure(Exception("Still starting up. Try again in a moment."))
        runCatching { TriageLabelDef.parseList(e.setTriageLabels(TriageLabelDef.listJson(labels))) }
            .onSuccess { stored -> TriageLabelNames.local = stored.associate { it.slug to it.name } }
    }

    private fun refreshTriageLabelNames() {
        TriageLabelNames.local = triageLabels().associate { it.slug to it.name }
    }

    /** Push an org's classifiable Spaces as the local classifier's taxonomy
     *  (`[{slug,name,description,not_for}]`). */
    suspend fun setSpaceTaxonomy(spacesJson: String) = withContext(Dispatchers.IO) {
        runCatching { engine?.setSpaceTaxonomy(spacesJson) }
            .onFailure { Log.e(TAG, "setSpaceTaxonomy failed: ${it.message}") }
        Unit
    }

    /** Push the user's AI model selection to the background triage worker. */
    fun setAiConfig(config: FfiBridgeConfig) { runCatching { engine?.setAiConfig(config) } }

    // ── Prompt templates (dev-mode editor) ──

    /** The persisted prompt-override file — mirrors desktop's `<data dir>/prompts.toml`. */
    private val promptsFile: File get() = File(dataDir, "prompts.toml")

    /** Per-section view of the active template: the persisted override's text where a
     *  section was edited, the embedded default otherwise (iOS EngineModel parity). */
    fun promptSections(): List<FfiPromptSection> {
        val e = engine ?: return emptyList()
        val stored = promptsFile.takeIf { it.exists() }?.readText()
        // A stored file that no longer validates falls back to the defaults view
        // (it was also skipped at launch, so this matches what's running).
        return runCatching { e.promptSections(stored) }.getOrNull()
            ?: runCatching { e.promptSections(null) }.getOrDefault(emptyList())
    }

    /** The embedded default text per section key — reset targets + edited detection. */
    fun defaultPromptSections(): Map<String, String> {
        val e = engine ?: return emptyMap()
        return runCatching { e.promptSections(null) }.getOrDefault(emptyList())
            .associate { it.key to it.text }
    }

    /** Build, validate, install, and persist a prompt override from the edited
     *  sections. Returns null on success, the validation message otherwise — on
     *  error nothing changes (the running prompts and the file stay as they were). */
    fun applyPromptSections(sections: List<FfiPromptSection>): String? {
        val e = engine ?: return "Still starting up. Try again in a moment."
        return try {
            val toml = e.buildPromptOverrides(sections)
            e.setPromptOverrides(toml.ifEmpty { null })
            if (toml.isEmpty()) promptsFile.delete() else promptsFile.writeText(toml)
            null
        } catch (ex: Exception) {
            ex.message ?: "invalid prompts"
        }
    }

    /** Change how far back mail is classified/summarized (optimistic). */
    suspend fun setProcessingWindow(window: ProcessingWindow) {
        val previous = _processingWindow.value
        _processingWindow.value = window.raw
        val ok = io { it.setProcessingWindow(window.raw); true } ?: false
        if (!ok) _processingWindow.value = previous
    }

    // ── Model manager (three-lane) ──────────────────────────────────────────

    fun modelLanes(capability: String, hasKey: Boolean): List<FfiLaneInfo> =
        runCatching { engine?.modelLanes(capability, hasKey) ?: emptyList() }.getOrDefault(emptyList())

    fun effectiveLane(capability: String, pref: BridgeLane, hasKey: Boolean): String =
        runCatching { engine?.effectiveLane(capability, pref.raw, hasKey) ?: BridgeLane.FREE.raw }
            .getOrDefault(BridgeLane.FREE.raw)

    fun downloadModel(id: String) {
        val e = engine ?: return
        _modelDownloads.value = _modelDownloads.value + (id to ModelDownload(id, "downloading", 0u, 0u, null))
        runCatching { e.modelDownload(id) }.onFailure { Log.e(TAG, "modelDownload $id failed: ${it.message}") }
    }

    fun deleteModel(id: String) {
        runCatching { engine?.modelDelete(id) }
        _modelDownloads.value = _modelDownloads.value - id
    }

    fun modelPath(id: String): String? = runCatching { engine?.modelPath(id) }.getOrNull()

    fun setHfToken(token: String?) { runCatching { engine?.setHfToken(token) } }

    // ── Sync ────────────────────────────────────────────────────────────────

    fun reload() { store.reopenIfNeeded(); refreshAccounts(); bump() }

    fun sync(accountKey: String? = null) {
        val e = engine ?: return
        val keys = accountKey?.let { listOf(it) } ?: _accounts.value.map { it.id }
        if (keys.isEmpty()) return
        _syncing.value = true
        scheduleSyncStop(12_000)
        for (key in keys) scope.launch(Dispatchers.IO) {
            runCatching { e.startSync(key) }.onFailure { Log.e(TAG, "startSync $key failed: ${it.message}") }
        }
    }

    suspend fun syncAllAndWait(): Boolean = withContext(Dispatchers.IO) {
        val e = engine ?: return@withContext false
        val keys = _accounts.value.map { it.id }
        if (keys.isEmpty()) return@withContext false
        keys.forEach { runCatching { e.startSync(it) } }
        store.reopenIfNeeded(); bump()
        true
    }

    private var syncStopJob: kotlinx.coroutines.Job? = null
    private fun scheduleSyncStop(ms: Long) {
        syncStopJob?.cancel()
        syncStopJob = scope.launch {
            kotlinx.coroutines.delay(ms)
            _syncing.value = false
        }
    }

    /** The on-device LLM callback, kept so the app can release the resident model. */
    private var bridgeLlm: BridgeLLM? = null

    /** Free the resident on-device model — called when the app goes to the background
     *  or the system signals memory pressure, so the suspended process isn't killed
     *  holding the large LiteRT engine (iOS background-unload parity). */
    fun unloadOnDeviceModel() { runCatching { bridgeLlm?.unloadModel() } }

    fun shutdown() { runCatching { engine?.shutdown() } }

    companion object {
        private const val TAG = "com.inbox2.engine"
        private val DATA_CHANGING = setOf("sync", "new-message", "calendar-changed")
        /** Shortest gap between two event-driven dataVersion bumps (mirrors iOS). */
        private const val DATA_BUMP_MS = 1000L

        // Process-wide singleton so the UI and the background SyncWorker share one engine
        // (one writer on inbox2.db). Opened lazily on first use.
        @Volatile private var instance: EngineModel? = null
        fun get(context: Context): EngineModel =
            instance ?: synchronized(this) {
                instance ?: EngineModel(context.applicationContext).also { instance = it }
            }

        /** The existing engine, or null — for lifecycle hooks that must NOT force the
         *  engine open (e.g. unloading the on-device model on background). */
        fun peek(): EngineModel? = instance
    }
}

/** Fetched live body + attachment metadata. */
data class FetchedMessage(
    val bodyHtml: String?,
    val bodyPlain: String?,
    val attachments: List<com.inbox2.app.model.AttachmentInfo>,
)

/** Account sync status values, mirrored from the core's AccountStatus (single source). */
object AccountStatusValue {
    const val CONNECTED = "connected"
    const val NEEDS_REAUTH = "needs_reauth"
    const val ERROR = "error"
}

/** A connected account, parsed resiliently from list_accounts_json. */
data class AccountRow(
    val id: String,
    val email: String,
    val provider: String,
    val status: String,
    val avatarURL: String?,
    /** Meta accounts only: the (non-secret) Meta app id, for grouping channels
     *  by app and reusing credentials. `null` for non-Meta accounts. */
    val metaAppId: String? = null,
    /** The core's last sync error reason (transient errors) — surfaced in the health banner. */
    val errorMessage: String? = null,
) {
    /** Dead credentials — the actionable "reconnect" case (iOS AccountRow.needsReauth). */
    val needsReauth: Boolean get() = status == AccountStatusValue.NEEDS_REAUTH
    /** Any unhealthy state worth surfacing a banner for (needs-reauth or a transient error). */
    val isFailing: Boolean get() = status == AccountStatusValue.NEEDS_REAUTH || status == AccountStatusValue.ERROR

    companion object {
        fun parse(json: String): List<AccountRow> = runCatching {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                AccountRow(
                    id = o.optString("key").ifEmpty { java.util.UUID.randomUUID().toString() },
                    email = o.optString("email_address").ifEmpty { o.optString("display_name", "account") },
                    provider = o.optString("provider_type"),
                    status = o.optString("status"),
                    avatarURL = o.optString("avatar_url").ifEmpty { null },
                    metaAppId = o.optString("meta_app_id").ifEmpty { null },
                    errorMessage = o.optString("error_message").ifEmpty { o.optString("last_error").ifEmpty { null } },
                )
            }
        }.getOrDefault(emptyList())
    }
}

/** Per-channel open-tracking settings (docs/Open-Tracking.md). */
data class OpenTrackingSettings(val enabled: Boolean, val trackDomain: String?) {
    companion object {
        fun parse(json: String?): OpenTrackingSettings {
            if (json.isNullOrEmpty()) return OpenTrackingSettings(false, null)
            val o = JSONObject(json)
            val td = o.optString("track_domain").ifEmpty { null }
            return OpenTrackingSettings(o.optBoolean("enabled", false), td)
        }
    }
}

/** One recorded open of a tracked sent message. */
data class MessageOpen(
    val openedAt: String,
    val ip: String?,
    val geoCountry: String?,
    val geoCity: String?,
    val proxied: Boolean,
    val proxyKind: String?,
    val userAgent: String?,
) {
    val location: String
        get() = listOfNotNull(geoCity, geoCountry).filter { it.isNotEmpty() }
            .joinToString(", ").ifEmpty { ip ?: "Unknown location" }

    companion object {
        fun parse(json: String?): List<MessageOpen> {
            if (json.isNullOrEmpty()) return emptyList()
            val arr = JSONArray(json)
            return (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                MessageOpen(
                    openedAt = o.optString("opened_at"),
                    ip = o.optString("ip").ifEmpty { null },
                    geoCountry = o.optString("geo_country").ifEmpty { null },
                    geoCity = o.optString("geo_city").ifEmpty { null },
                    proxied = o.optBoolean("proxied", false),
                    proxyKind = o.optString("proxy_kind").ifEmpty { null },
                    userAgent = o.optString("user_agent").ifEmpty { null },
                )
            }
        }
    }
}

/** Live state of a Bridge model download, parsed from a `model-download` event. */
data class ModelDownload(
    val id: String,
    val state: String,
    val received: ULong,
    val total: ULong,
    val error: String?,
) {
    val isInstalled get() = state == "installed"
    val isActive get() = state in listOf("downloading", "verifying", "installing")
    val fraction: Float? get() = if (total > 0u) (received.toDouble() / total.toDouble()).toFloat().coerceAtMost(1f) else null

    companion object {
        fun fromJson(payload: String): ModelDownload? = runCatching {
            val o = JSONObject(payload)
            ModelDownload(
                id = o.optString("id").ifEmpty { return null },
                state = o.optString("state").ifEmpty { return null },
                received = o.optLong("received_bytes", 0).toULong(),
                total = o.optLong("total_bytes", 0).toULong(),
                error = o.optString("error").ifEmpty { null },
            )
        }.getOrNull()
    }
}

/** Bridge lane preference, 1:1 with the iOS BridgeLane. */
enum class BridgeLane(val raw: String) { NATIVE("native"), FREE("free"), OPENAI("openai") }

/** Bridge capability, 1:1 with the iOS BridgeCapability. */
enum class BridgeCapability(val raw: String) { STT("stt"), TTS("tts"), NLU("nlu") }
