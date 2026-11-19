package com.inbox2.app.ui.screens

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.model.AccountKey
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConversationAction
import com.inbox2.app.model.InboxFilter
import com.inbox2.app.model.MailFolder
import com.inbox2.app.model.RelativeTime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Minimum characters before a typed query hits the store — shorter fragments match
 *  nearly everything and make the type-to-search scan crawl. */
internal const val MIN_SEARCH_CHARS = 3
/** Idle time (ms) after the last keystroke before the search fires. */
private const val SEARCH_DEBOUNCE_MS = 280L

/** Non-UI state for InboxScreen: rows/query/filter, the multi-select set, undo state,
 *  pending-removal reconciliation, and the applyAction/bulk entry points. The suspend
 *  members are driven by the screen's LaunchedEffects so cancellation semantics
 *  (debounce restart per keystroke, undo timer restart per toast) stay with the
 *  composition. */
class InboxState(
    val engine: EngineModel,
    val cloud: CloudSession,
    private val scope: CoroutineScope,
    private val ctx: Context,
) {
    var channel by mutableStateOf<String?>(null)
    var filter by mutableStateOf(InboxFilter.ALL)
    // Live text in the search field (every keystroke).
    var query by mutableStateOf("")
    // Debounced + min-length-gated term actually applied to the read. Empty while the
    // user has typed fewer than 3 characters, so short fragments don't kick off a
    // full-store scan on every key.
    var effectiveQuery by mutableStateOf("")
    // A search read is in flight (covers the debounce wait + the fetch) — drives the
    // spinner in the search field.
    var searching by mutableStateOf(false)
    /** The local store read failed (disk I/O, corruption). Distinct from an empty
     *  inbox — iOS InboxListView.loadError. */
    var loadError by mutableStateOf<String?>(null)
    var rows by mutableStateOf<List<Conversation>>(emptyList())
    /** Gmail/Outlook-side search hits for the current query + scope. Cached because
     *  [reload] also runs on every engine data event, and those must not each cost a
     *  provider request. */
    private var providerHitCache: Pair<String, List<String>>? = null
    var undo by mutableStateOf<UndoState?>(null)
    var selected by mutableStateOf<Set<String>>(emptySet())
    var unreadCount by mutableIntStateOf(0)
    var domainView by mutableStateOf("All")   // mx pool views

    val editing get() = selected.isNotEmpty()
    val isDomainChannel get() = AccountKey.isDomain(channel)
    /** Below the min-chars gate, so no search will run for the typed fragment. */
    val searchTooShort get() = query.trim().let { it.isNotEmpty() && it.length < MIN_SEARCH_CHARS }
    /** Text in the search field but no result set on screen yet (too short, or the
     *  first debounce/fetch is in flight) — the list must not show the normal inbox
     *  behind an active search (iOS searchPending). */
    val searchPending get() = query.trim().isNotEmpty() && effectiveQuery.isEmpty()

    /** Snooze a domain thread (iOS snoozeRow): the row leaves now, no undo — the
     *  server owns the wake-up. */
    fun snooze(c: Conversation, until: java.util.Date) {
        rows = rows.filterNot { it.id == c.id }
        engine.markRemoved(listOf(c.id))
        com.inbox2.app.notify.NotificationHelper.removeDelivered(ctx, listOf(c.id))
        scope.launch { cloud.snooze(c.accountKey, c.id, java.time.Instant.ofEpochMilli(until.time).toString()) }
    }

    /** Apply an action with optimistic row removal + an undo toast for reversible
     *  removals. One path for the swipe/menu (single row) and the bulk bar (N rows):
     *  capture each row's position before removal so undo can restore in place, clear
     *  the threads' notifications now (the launcher badge is notification-driven)
     *  instead of waiting for reconcileNotifications, then route each account's batch
     *  to the cloud or the engine. */
    fun applyAction(targets: List<Conversation>, action: ConversationAction) {
        if (targets.isEmpty()) return
        if (action.removesRow) {
            val items = targets.mapNotNull { c ->
                rows.indexOfFirst { it.id == c.id }.takeIf { it >= 0 }?.let { UndoState.Item(c, it) }
            }
            val ids = targets.mapTo(HashSet()) { it.id }
            rows = rows.filterNot { it.id in ids }
            engine.markRemoved(ids)
            if (action.reverse != null) undo = UndoState(items, action)
        }
        if (action.clearsNotification)
            com.inbox2.app.notify.NotificationHelper.removeDelivered(ctx, targets.map { it.id })
        targets.groupBy { it.accountKey }.forEach { (acct, list) ->
            scope.launch { engine.performRouted(cloud, acct, list.map { it.id }, action.verb) }
        }
    }
    fun applyAction(c: Conversation, action: ConversationAction) = applyAction(listOf(c), action)

    /** Bulk-bar entry point: apply to the current selection, then leave edit mode. */
    fun bulk(action: ConversationAction) {
        val targets = rows.filter { it.id in selected }
        if (targets.isEmpty()) return
        applyAction(targets, action)
        selected = emptySet()
    }

    /** Reverse every captured row, one engine/cloud call per account. */
    fun undoRestore(u: UndoState) {
        u.action.reverse?.let { rev ->
            // Stop suppressing the restored rows from re-queries.
            engine.unmarkRemoved(u.items.map { it.convo.id })
            // Lore's per-member ticks have their own reverse, and the row never left the list.
            u.items.groupBy { it.convo.accountKey to (it.reverse ?: rev) }.forEach { (key, list) ->
                scope.launch { engine.performRouted(cloud, key.first, list.map { it.convo.id }, key.second.verb) }
            }
            val flipped = u.items.filter { it.reverse != null }.mapTo(HashSet()) { it.convo.id }
            if (flipped.isNotEmpty()) rows = rows.map { if (it.id in flipped) it.copy(loreDone = false) else it }
        }
        undo = null
    }

    /** A triage result landed: upgrade the loaded row in place (label + one-liner
     *  preview) instead of re-querying the whole list. Returns false when the row
     *  isn't loaded and the view is triage-scoped — there a fresh label can add a
     *  row, so the caller should reload. */
    fun applyTriagePatch(p: EngineModel.TriagePatch, folder: MailFolder): Boolean {
        val i = rows.indexOfFirst { it.id == p.key }
        if (i >= 0) {
            rows = rows.toMutableList().also {
                it[i] = it[i].copy(
                    triageLabel = p.label ?: it[i].triageLabel,
                    triagePriority = p.priority ?: it[i].triagePriority,
                    aiSummaryShort = p.summaryShort ?: it[i].aiSummaryShort,
                )
            }
            return true
        }
        return !(filter == InboxFilter.TRIAGED || folder.triageLabel != null)
    }

    /** Debounce typing and gate on a minimum length: fragments shorter than 3 chars
     *  clear the search (full inbox shows) instead of scanning the whole store on every
     *  keystroke. The spinner runs for the whole wait. The caller's LaunchedEffect(query)
     *  re-runs (cancelling the prior delay) on each keystroke — that's the debounce. */
    suspend fun runSearchDebounce() {
        val trimmed = query.trim()
        if (trimmed.length < MIN_SEARCH_CHARS) {
            searching = false
            if (effectiveQuery.isNotEmpty()) effectiveQuery = ""
            return
        }
        searching = true
        delay(SEARCH_DEBOUNCE_MS)
        // If the term is unchanged no reload fires to clear the spinner, so clear it here.
        if (effectiveQuery != trimmed) effectiveQuery = trimmed else searching = false
    }

    /** The store/cloud read + pending-removal reconciliation. Three source shapes:
     *  a specific domain chip → that domain's MX pool; a specific channel chip → that
     *  channel's local store; unified (`channel == null`) → BOTH merged. */
    /** `pages` > 1 (Lore: an old open task must not drop off Today; History reads the
     *  archive) reads that many MX pages per org and takes the unified path for any folder. */
    suspend fun reload(folder: MailFolder, pages: Int = 1, labeledOnly: Boolean = false) {
        val fetched = when {
            isDomainChannel ->
                // The selected chip is a `dom_…` (per-domain) or `org_…` (legacy) key; the API
                // path always uses the org id, with the domain passed as the `?domain=` filter.
                cloud.activeOrg.value?.let { org -> runCatching { cloud.conversations(org, folder, effectiveQuery, domainView, AccountKey.domainFilter(channel)) }.getOrDefault(emptyList()) } ?: emptyList()
            channel != null ->
                withContext(Dispatchers.IO) { engine.store.conversations(channel, folder, filter, effectiveQuery, labeledOnly) }
            else -> {
                // Global unified: union the local channels with every signed-in org's whole
                // MX pool (no domain filter). MX merges only into the standard Inbox — Sent/
                // Drafts/Archive/Trash stay per-source, reachable via a specific chip.
                val channelRows = withContext(Dispatchers.IO) { engine.store.conversations(null, folder, filter, effectiveQuery, labeledOnly) }
                // MX merges into the standard Inbox and into search (any folder); other
                // special folders (Sent/Drafts/Archive/Trash) stay channel-only in unified.
                val mxRows = if (folder == MailFolder.INBOX || effectiveQuery.isNotEmpty() || pages > 1)
                    cloud.orgs.value.flatMap { org ->
                        val rows = mutableListOf<Conversation>()
                        for (page in 1..maxOf(1, pages)) {
                            val batch = runCatching { cloud.conversations(org.id, folder, effectiveQuery, filter.label, null, page, labeledOnly) }.getOrDefault(emptyList())
                            rows += batch
                            if (batch.size < 50 || effectiveQuery.isNotEmpty()) break   // a short page is the last; search isn't paged
                        }
                        rows
                    } else emptyList()
                // De-dupe by conversation key, then sort by parsed activity date descending
                // with one comparator over the whole merged array.
                (channelRows + mxRows)
                    .associateBy { it.id }.values
                    .sortedByDescending { RelativeTime.parse(it.updatedAt)?.time ?: 0L }
            }
        }
        // A failed local read must not pass for an empty inbox (iOS diskError).
        loadError = if (isDomainChannel) null else engine.store.lastReadError
        // Suppress just-removed rows the store may still return until the write-back
        // commits (the post-action dataVersion bump can re-query before the trash
        // write lands), then drop keys it no longer returns — the store has reconciled.
        val pending = engine.pendingRemoved.value
        if (pending.isNotEmpty()) {
            val present = fetched.mapTo(HashSet()) { it.id }
            engine.unmarkRemoved(pending - present)
        }
        rows = fetched.filterNot { it.id in engine.pendingRemoved.value }
        if (!isDomainChannel) appendProviderHits()
        unreadCount = if (folder != MailFolder.INBOX) 0
            else when {
                // Unified: the combined total AppBadge already sums for the OS badge —
                // local-channel unread + every org's MX unread.
                channel == null -> withContext(Dispatchers.IO) { engine.store.unreadCount(null) } +
                    cloud.orgs.value.sumOf { cloud.unreadCount(it.id) }
                !isDomainChannel -> withContext(Dispatchers.IO) { engine.store.unreadCount(channel) }
                else -> 0
            }
        searching = false
    }

    /** Second search pass: Gmail/Outlook search their own index, which reads inside
     *  attachments (local FTS only has filenames), so a word that lives only in an
     *  attached PDF still finds its thread. Local rows are already set; the provider's
     *  extra hits are merged in. */
    private suspend fun appendProviderHits() {
        val q = effectiveQuery
        // Exclusions alone (-word) name nothing to look for: the provider would just list recent mail.
        if (q.isEmpty() || !engine.store.hasSearchTerms(q)) return
        val scope = "${channel ?: "*"}|$q"
        val keys = providerHitCache?.takeIf { it.first == scope }?.second
            ?: engine.providerSearch(channel, q).also { providerHitCache = scope to it }
        val seen = rows.mapTo(HashSet()) { it.id }
        val missing = keys.filterNot { it in seen || it in engine.pendingRemoved.value }
        if (missing.isEmpty()) return
        val f = filter
        val extra = withContext(Dispatchers.IO) { engine.store.conversationsByKeys(missing, f) }
        rows = (rows + extra).sortedByDescending { RelativeTime.parse(it.updatedAt)?.time ?: 0L }
    }

    /** Auto-dismiss the undo toast after 5 s; the identity check keeps a newer toast
     *  alive when the caller's LaunchedEffect(undo) restarted this for it. */
    suspend fun expireUndo() {
        val u = undo ?: return
        delay(5000)
        if (undo === u) undo = null
    }
}

@Composable
fun rememberInboxState(engine: EngineModel, cloud: CloudSession): InboxState {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    return remember { InboxState(engine, cloud, scope, ctx) }
}

/** The bulk/swipe action that restores a thread to the inbox, keyed off the folder. */
fun folderRestoreAction(folder: MailFolder): ConversationAction? = when (folder) {
    MailFolder.ARCHIVE -> ConversationAction.Unarchive
    MailFolder.SPAM -> ConversationAction.Unspam
    MailFolder.TRASH -> ConversationAction.Untrash
    else -> null   // standard folders archive
}

data class UndoState(val items: List<Item>, val action: ConversationAction) {
    /** One removed row + its original position (1 for a swipe, N for a bulk action). */
    data class Item(val convo: Conversation, val index: Int, val reverse: ConversationAction? = null)
    val primary: Conversation? get() = items.firstOrNull()?.convo
    val count: Int get() = items.size
}
