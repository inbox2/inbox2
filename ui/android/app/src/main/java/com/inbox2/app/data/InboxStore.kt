package com.inbox2.app.data

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import android.util.Log
import com.inbox2.app.model.ActivityEntry
import com.inbox2.app.model.CalendarEvent
import com.inbox2.app.model.CalendarStatusValue
import com.inbox2.app.model.Contact
import com.inbox2.app.model.Conversation
import com.inbox2.app.model.ConvStatusValue
import com.inbox2.app.model.InboxFilter
import com.inbox2.app.model.LocalAgent
import com.inbox2.app.model.LocalRule
import com.inbox2.app.model.MailAddress
import com.inbox2.app.model.MailFolder
import com.inbox2.app.model.Message
import com.inbox2.app.model.OutboxItem
import com.inbox2.app.model.OutboxStatusValue
import com.inbox2.app.model.WritableCalendar
import java.io.File

/**
 * Read access to the local `inbox2.db`, mirroring the iOS InboxStore (which itself
 * mirrors the desktop frontend SQLite read path). On every platform the UI reads
 * conversations/messages straight from SQLite and only *writes* through the Rust
 * engine — this keeps that split on Android. The same file the Rust SyncEngine opens
 * for writes is opened here read-write but used SELECT-only, so reads always reflect
 * the engine's committed writes (WAL, second in-process connection). See iOS-App.md §4.
 */
class InboxStore(private val dbPath: String) {
    private var db: SQLiteDatabase? = null
    private val lock = Any()
    private var contactsCache: List<Contact>? = null

    /** The last SQLite failure (open, disk I/O, corruption) — the raw message. Cleared
     *  at the start of every list read so the inbox can tell "no mail" from "couldn't
     *  read" (iOS InboxLoad.diskError). */
    @Volatile var lastReadError: String? = null
        private set

    /** FTS5 MATCH → conversation keys, run by the Rust core. Android's platform SQLite
     *  ships without the FTS5 module ("no such module: fts5"), so the MATCH can't run on
     *  this connection; the core bundles SQLite with FTS5 and owns the index anyway.
     *  Set by EngineModel; null falls back to a local MATCH (a device whose SQLite has it). */
    @Volatile var ftsKeys: ((match: String, limit: Int) -> List<String>)? = null

    init { open() }

    private fun open() {
        if (!File(dbPath).exists()) {
            Log.i(TAG, "store not present yet at $dbPath — empty until an account syncs")
            return
        }
        runCatching {
            db = SQLiteDatabase.openDatabase(
                dbPath, null,
                SQLiteDatabase.OPEN_READWRITE or SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING,
            )
            Log.i(TAG, "opened local store at $dbPath")
        }.onFailure {
            Log.e(TAG, "failed to open store at $dbPath: ${it.message}")
            lastReadError = it.message ?: it.toString()
            db = null
        }
    }

    /** Reopen if the file appeared after init (first sync creates it). */
    fun reopenIfNeeded() = synchronized(lock) { if (db == null) open() }

    /** Drop the derived contacts cache so the next read reflects newly-synced mail —
     *  otherwise new correspondents never appear in autocomplete until process restart. */
    fun invalidateContactsCache() = synchronized(lock) { contactsCache = null }

    // ── Conversations ───────────────────────────────────────────────────────

    /** `labeledOnly` (Lore): only threads carrying a triage label, up to 1000 — so an old
     *  open Lore task doesn't fall outside the inbox's newest-200 window (iOS parity). */
    fun conversations(accountKey: String?, folder: MailFolder, filter: InboxFilter, query: String, labeledOnly: Boolean = false): List<Conversation> =
        synchronized(lock) {
            lastReadError = null
            val d = db ?: run { if (File(dbPath).exists()) lastReadError = "The mail store could not be opened."; return emptyList() }
            val trimmed = query.trim()
            if (trimmed.isNotEmpty()) return searchFTS(d, accountKey, filter, trimmed)
            if (filter == InboxFilter.TRIAGED) return triaged(d, accountKey)
            folder.triageLabel?.let { return triageQuery(d, accountKey, it, filter) }
            if (folder.isMeta) return metaQuery(d, accountKey, folder.metaKinds, filter)
            when (folder) {
                MailFolder.SENT -> return folderRoleQuery(d, accountKey, "sent", filter)
                MailFolder.DRAFTS -> return draftsQuery(d, accountKey)
                MailFolder.INBOX -> return inboxQuery(d, accountKey, filter, labeledOnly)
                else -> {}
            }
            val conditions = mutableListOf<String>()
            val binds = mutableListOf<String>()
            when (folder) {
                MailFolder.ARCHIVE -> conditions.add("status = '${ConvStatusValue.ARCHIVED}'")
                MailFolder.SPAM -> conditions.add("status = '${ConvStatusValue.SPAM}'")
                MailFolder.TRASH -> conditions.add("status = '${ConvStatusValue.TRASH}'")
                else -> conditions.add(statusNotIn(ConvStatusValue.inboxHidden))
            }
            if (accountKey != null) { conditions.add("organization_id = ?"); binds.add(accountKey) }
            if (filter == InboxFilter.UNREAD) conditions.add("read = 0")
            if (labeledOnly) conditions.add("triage_label IS NOT NULL AND triage_label != 'resolved'")
            val sql = """
                SELECT $CONV_COLS
                FROM conversations
                WHERE ${conditions.joinToString(" AND ")}
                ORDER BY updated_at DESC LIMIT ${if (labeledOnly) 1000 else 200}
            """.trimIndent()
            mapAll(d, sql, binds) { mapConversation(it) }
        }

    private fun inboxQuery(d: SQLiteDatabase, accountKey: String?, filter: InboxFilter, labeledOnly: Boolean = false): List<Conversation> {
        val conditions = mutableListOf(
            statusNotIn(ConvStatusValue.inboxHidden, "c.status"),
        )
        val binds = mutableListOf<String>()
        if (accountKey != null) { conditions.add("c.organization_id = ?"); binds.add(accountKey) }
        if (filter == InboxFilter.UNREAD) conditions.add("c.read = 0")
        if (labeledOnly) conditions.add("c.triage_label IS NOT NULL AND c.triage_label != 'resolved'")
        // Drive inbox membership from the indexed (account_key, folder_key) inbox
        // set, NOT a JOIN/scan over every message. Every inbox message reliably
        // carries an mps row whose folder_key is the inbox folder (verified across
        // Gmail/MS/IMAP — the labels-LIKE alternative finds nothing folder_key
        // doesn't), so we avoid both the unindexable `labels LIKE` and the
        // JOIN+DISTINCT row-explosion. For a large archived account this is the
        // difference between scanning all its conversations (~2s) and reading the
        // small inbox set. Bind accountKey again for the folder filter (iOS parity:
        // InboxStore.swift inboxQuery).
        var folderAccountClause = ""
        if (accountKey != null) { binds.add(accountKey); folderAccountClause = " AND f.account_key = ?" }
        val sql = """
            SELECT ${CONV_COLS_C}
            FROM conversations c
            WHERE ${conditions.joinToString(" AND ")}
              AND c.key IN (
                SELECT m.conversation_key FROM message_provider_state mps
                JOIN messages m ON m.key = mps.message_key
                WHERE mps.folder_key IN (
                  SELECT f.key FROM external_folders f
                  WHERE f.well_known_role = 'inbox'$folderAccountClause
                )
              )
            ORDER BY c.updated_at DESC LIMIT ${if (labeledOnly) 1000 else 200}
        """.trimIndent()
        return mapAll(d, sql, binds) { mapConversation(it) }
    }

    private fun folderRoleQuery(d: SQLiteDatabase, accountKey: String?, role: String, filter: InboxFilter): List<Conversation> {
        val conditions = mutableListOf("f.well_known_role = ?")
        val binds = mutableListOf(role)
        if (accountKey != null) { conditions.add("c.organization_id = ?"); binds.add(accountKey) }
        if (filter == InboxFilter.UNREAD) conditions.add("c.read = 0")
        val sql = """
            SELECT DISTINCT ${CONV_COLS_C}
            FROM conversations c
            JOIN messages m ON m.conversation_key = c.key
            JOIN message_provider_state mps ON mps.message_key = m.key
            JOIN external_folders f ON f.key = mps.folder_key
            WHERE ${conditions.joinToString(" AND ")}
            ORDER BY c.updated_at DESC LIMIT 200
        """.trimIndent()
        return mapAll(d, sql, binds) { mapConversation(it) }
    }

    private fun triageQuery(d: SQLiteDatabase, accountKey: String?, label: String, filter: InboxFilter): List<Conversation> {
        val conditions = mutableListOf(
            "f.provider_name = ?",
            "mps.labels LIKE '%' || replace(substr(f.key, instr(f.key, '_label_') + 1), 'label_', 'Label_') || '%'",
            statusNotIn(ConvStatusValue.discarded, "c.status"),
        )
        val binds = mutableListOf(label)
        if (accountKey != null) { conditions.add("c.organization_id = ?"); binds.add(accountKey) }
        if (filter == InboxFilter.UNREAD) conditions.add("c.read = 0")
        val sql = """
            SELECT DISTINCT ${CONV_COLS_C}
            FROM conversations c
            JOIN messages m ON m.conversation_key = c.key
            JOIN message_provider_state mps ON mps.message_key = m.key AND mps.account_key = c.organization_id
            JOIN external_folders f ON f.account_key = c.organization_id
            WHERE ${conditions.joinToString(" AND ")}
            ORDER BY c.updated_at DESC LIMIT 200
        """.trimIndent()
        return mapAll(d, sql, binds) { mapConversation(it) }
    }

    private fun draftsQuery(d: SQLiteDatabase, accountKey: String?): List<Conversation> {
        val conditions = mutableListOf("m.is_draft = 1")
        val binds = mutableListOf<String>()
        if (accountKey != null) { conditions.add("c.organization_id = ?"); binds.add(accountKey) }
        val sql = """
            SELECT DISTINCT ${CONV_COLS_C}
            FROM conversations c
            JOIN messages m ON m.conversation_key = c.key
            WHERE ${conditions.joinToString(" AND ")}
            ORDER BY c.updated_at DESC LIMIT 200
        """.trimIndent()
        return mapAll(d, sql, binds) { mapConversation(it) }
    }

    /** Meta channel sub-view: conversations narrowed by `kind` (null = all), scoped
     *  to the account, hiding trash/spam/archived. Mirrors the desktop/iOS sub-views. */
    private fun metaQuery(d: SQLiteDatabase, accountKey: String?, kinds: List<String>?, filter: InboxFilter): List<Conversation> {
        val conditions = mutableListOf(statusNotIn(ConvStatusValue.inboxHidden))
        val binds = mutableListOf<String>()
        if (accountKey != null) { conditions.add("organization_id = ?"); binds.add(accountKey) }
        if (!kinds.isNullOrEmpty()) {
            conditions.add("kind IN (${kinds.joinToString(", ") { "?" }})")
            binds.addAll(kinds)
        }
        if (filter == InboxFilter.UNREAD) conditions.add("read = 0")
        val sql = """
            SELECT $CONV_COLS
            FROM conversations
            WHERE ${conditions.joinToString(" AND ")}
            ORDER BY updated_at DESC LIMIT 200
        """.trimIndent()
        return mapAll(d, sql, binds) { mapConversation(it) }
    }

    private fun triaged(d: SQLiteDatabase, accountKey: String?): List<Conversation> {
        val conditions = mutableListOf(
            statusNotIn(ConvStatusValue.discarded),
            "(priority_urgent = 1 OR priority_important = 1)",
        )
        val binds = mutableListOf<String>()
        if (accountKey != null) { conditions.add("organization_id = ?"); binds.add(accountKey) }
        val sql = """
            SELECT ${CONV_COLS}
            FROM conversations
            WHERE ${conditions.joinToString(" AND ")}
            ORDER BY updated_at DESC LIMIT 200
        """.trimIndent()
        return mapAll(d, sql, binds) { mapConversation(it) }
    }

    /** Conversation rows for keys a provider-side search returned (Gmail/Outlook read
     *  inside attachments; local FTS doesn't). Trashed/discarded stay out, like FTS. */
    fun conversationsByKeys(keys: List<String>, filter: InboxFilter = InboxFilter.ALL): List<Conversation> = synchronized(lock) {
        val d = db ?: return emptyList()
        if (keys.isEmpty()) return emptyList()
        val sql = """
            SELECT ${CONV_COLS_C} FROM conversations c
            WHERE c.key IN (${keys.joinToString(",") { "?" }})
              AND ${statusNotIn(ConvStatusValue.discarded, "c.status")}
              ${filterClause(filter)?.let { "AND $it" } ?: ""}
        """.trimIndent()
        mapAll(d, sql, keys) { mapConversation(it) }
    }

    private fun searchFTS(d: SQLiteDatabase, accountKey: String?, filter: InboxFilter, query: String): List<Conversation> {
        val match = buildFtsMatch(query)
        if (match.isEmpty()) return emptyList()
        // The core's MATCH knows nothing about account/status/unread, so ask for far more
        // than the list shows and filter here. ponytail: a flat 2000; pass the filters into
        // the core query if a mailbox ever has more matches than that for one word.
        val viaCore = ftsKeys?.let { runCatching { it(match, 2000) }.onFailure { lastReadError = it.message }.getOrNull() }
        val conditions = mutableListOf(statusNotIn(ConvStatusValue.discarded, "c.status"))
        val binds = mutableListOf<String>()
        if (viaCore != null) {
            if (viaCore.isEmpty()) return emptyList()
            conditions.add("c.key IN (${viaCore.joinToString(",") { "?" }})"); binds.addAll(viaCore)
        } else { conditions.add("messages_fts MATCH ?"); binds.add(match) }
        if (accountKey != null) { conditions.add("c.organization_id = ?"); binds.add(accountKey) }
        filterClause(filter)?.let(conditions::add)
        val from = if (viaCore != null) "conversations c"
            else "messages_fts fts JOIN messages m ON m.rowid = fts.rowid JOIN conversations c ON c.key = m.conversation_key"
        val sql = """
            SELECT DISTINCT ${CONV_COLS_C}
            FROM $from
            WHERE ${conditions.joinToString(" AND ")}
            ORDER BY c.updated_at DESC LIMIT 100
        """.trimIndent()
        return mapAll(d, sql, binds) { mapConversation(it) }
    }

    /** Mirror of the iOS buildFtsMatch: AND-ed quoted terms, or/and operators, trailing `*`. */
    /** The Unread/Triaged pill as a WHERE condition (null for All), shared by the FTS
     *  search and the provider hits merged into it. */
    private fun filterClause(filter: InboxFilter): String? = when (filter) {
        InboxFilter.ALL -> null
        InboxFilter.UNREAD -> "c.read = 0"
        InboxFilter.TRIAGED -> "(c.priority_urgent = 1 OR c.priority_important = 1)"
    }

    /** Whether the query names anything to look for (exclusions alone don't). */
    fun hasSearchTerms(query: String): Boolean = buildFtsMatch(query).isNotEmpty()

    private fun buildFtsMatch(query: String): String {
        val tokens = Regex("-?\"[^\"]*\"|\\S+").findAll(query).map { it.value }.toList()
        val parts = mutableListOf<String>()
        val excluded = mutableListOf<String>()
        for (tok in tokens) {
            // `-word` / `-"a phrase"` excludes. Quoted as a term it would REQUIRE the
            // word instead (the tokenizer drops the dash).
            if (tok.length > 1 && tok.startsWith("-")) {
                val inner = tok.drop(1).replace("\"", "").trim()
                if (inner.isNotEmpty()) excluded.add("\"$inner\"")
                continue
            }
            val upper = tok.uppercase()
            if (upper == "OR" || upper == "AND") {
                val prev = parts.lastOrNull()
                if (prev == null || prev == "OR" || prev == "AND") continue
                parts.add(upper); continue
            }
            var inner = tok
            if (inner.startsWith("\"") && inner.endsWith("\"") && inner.length >= 2) inner = inner.substring(1, inner.length - 1)
            inner = inner.replace("\"", "").trim()
            if (inner.isNotEmpty()) parts.add("\"$inner\"")
        }
        while (parts.lastOrNull() == "OR" || parts.lastOrNull() == "AND") parts.removeAt(parts.size - 1)
        if (parts.isEmpty()) return ""
        val last = parts.last()
        if (last.startsWith("\"")) parts[parts.size - 1] = last + "*"
        // FTS5 NOT is binary, so exclusions trail the bracketed rest (an OR in it
        // can't let excluded mail back in).
        if (excluded.isEmpty()) return parts.joinToString(" ")
        return "(${parts.joinToString(" ")}) NOT " + excluded.joinToString(" NOT ")
    }

    // Unread count for badges (null = unified). MUST match what the Inbox shows,
    // so it uses the same provider-INBOX membership as [inboxQuery] (not a bare
    // status filter) — otherwise open+unread threads not in the provider inbox
    // (sent replies, server-side moved/archived, Meta channels shown only in their
    // sub-views) inflate the count while the inbox reads 0.
    fun unreadCount(accountKey: String?): Int = synchronized(lock) {
        val d = db ?: return 0
        val conditions = mutableListOf(
            statusNotIn(ConvStatusValue.inboxHidden, "c.status"),
            "c.read = 0",
        )
        val binds = mutableListOf<String>()
        if (accountKey != null) { conditions.add("c.organization_id = ?"); binds.add(accountKey) }
        // Drive from unread conversations + EXISTS, not a JOIN through
        // message_provider_state: the join form full-SCANs provider-state
        // (which archive/All-Mail sync grew to tens of thousands of rows),
        // costing seconds for the unified badge regardless of unread count.
        // EXISTS short-circuits at the first inbox message.
        //
        // Membership MUST match [inboxQuery] (the list the user sees) or the
        // badge phantoms over an empty inbox: a `labels LIKE '%"INBOX"%'` OR
        // branch here once counted conversations whose label-blob still held
        // "INBOX" after they left the inbox folder — rows the list never shows.
        // The inbox-folder set alone is complete (see inboxQuery), so key off it.
        val sql = """
            SELECT COUNT(*)
            FROM conversations c
            WHERE ${conditions.joinToString(" AND ")}
              AND EXISTS (
                SELECT 1 FROM messages m
                JOIN message_provider_state mps ON mps.message_key = m.key
                JOIN external_folders ef ON ef.key = mps.folder_key AND ef.account_key = c.organization_id
                WHERE m.conversation_key = c.key
                  AND ef.well_known_role = 'inbox'
              )
        """.trimIndent()
        mapAll(d, sql, binds) { it.getInt(0) }.firstOrNull() ?: 0
    }

    fun conversation(key: String): Conversation? = synchronized(lock) {
        val d = db ?: return null
        // summaries_current: the AI summaries were generated for the latest message
        // (the same currency rule the core's email-voice uses; iOS parity).
        val sql = """
            SELECT $CONV_COLS,
                   (ai_meta_msg_key IS NOT NULL AND ai_meta_msg_key = (
                        SELECT m.key FROM messages m WHERE m.conversation_key = conversations.key
                        ORDER BY m.created_at DESC LIMIT 1)) AS summaries_current
            FROM conversations WHERE key = ? LIMIT 1
        """
        mapAll(d, sql, listOf(key)) { mapConversation(it).copy(summariesCurrent = it.getInt(20) == 1) }.firstOrNull()
    }

    fun recentActivity(limit: Int = 40): List<ActivityEntry> = synchronized(lock) {
        val d = db ?: return emptyList()
        val sql = """
            SELECT m.key, m.from_address, m.created_at, m.conversation_key, c.subject, c.read
            FROM messages m
            JOIN conversations c ON c.key = m.conversation_key
            WHERE m.is_inbound = 1 AND ${statusNotIn(ConvStatusValue.discarded, col = "c.status")}
            ORDER BY m.created_at DESC LIMIT ?
        """.trimIndent()
        mapAll(d, sql, listOf(limit.toString())) {
            ActivityEntry(it.s(0), it.s(1), it.s(2), it.s(3), it.s(4), it.getInt(5) == 0)
        }
    }

    // ── Rules / agents (read-only) ──────────────────────────────────────────

    fun localRules(): List<LocalRule> = synchronized(lock) {
        val d = db ?: return emptyList()
        val sql = "SELECT key, name, conditions, action, enabled, account_key FROM local_rules ORDER BY created_at DESC"
        mapAll(d, sql, emptyList()) {
            LocalRule(it.s(0), it.s(1), it.s(2), it.s(3), it.getInt(4) == 1, it.sn(5))
        }
    }

    fun localAgents(): List<LocalAgent> = synchronized(lock) {
        val d = db ?: return emptyList()
        val sql = "SELECT display_name, adapter_id, version, enabled FROM local_agents ORDER BY enabled DESC, display_name"
        mapAll(d, sql, emptyList()) { LocalAgent(it.s(0), it.s(1), it.sn(2), it.getInt(3) == 1) }
    }

    // ── Outbox ──────────────────────────────────────────────────────────────

    fun outboxMessages(): List<OutboxItem> = synchronized(lock) {
        val d = db ?: return emptyList()
        val placeholders = OutboxStatusValue.queued.joinToString(",") { "'$it'" }
        val sql = """
            SELECT key, account_key, payload, status, retry_count, max_retries, error_message, created_at
            FROM outbox_messages WHERE status IN ($placeholders) ORDER BY created_at DESC
        """.trimIndent()
        mapAll(d, sql, emptyList()) {
            OutboxItem(it.s(0), it.s(1), it.s(2), it.s(3), it.getInt(4), it.getInt(5), it.sn(6), it.s(7))
        }
    }

    // ── Contacts ──────────────────────────────────────────────────────────────

    private class Ranked(val name: String, val total: Int, val score: Double)

    /** Age buckets (newest cutoff first) for ranking correspondents: someone you mailed
     *  weekly this year should outrank someone with a bigger lifetime thread count from
     *  four years ago. `updated_at` is an ISO internet date-time, so its "yyyy-MM-dd"
     *  prefix compares lexicographically — no date parsing per row over the whole table.
     *  ponytail: fixed buckets, not a continuous half-life — swap in a decay curve only
     *  if the steps ever show up as visibly wrong ordering. */
    private fun recencyBuckets(now: Long = System.currentTimeMillis()): List<Pair<String, Double>> {
        val f = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        f.timeZone = java.util.TimeZone.getTimeZone("UTC")
        return listOf(30 to 16.0, 90 to 8.0, 365 to 4.0, 730 to 2.0, 1460 to 1.0).map { (days, w) ->
            f.format(java.util.Date(now - days * 86_400_000L)) to w
        }
    }

    private fun recencyWeight(updatedAt: String, buckets: List<Pair<String, Double>>): Double {
        val day = updatedAt.take(10)
        for ((cutoff, w) in buckets) if (day >= cutoff) return w
        return 0.5   // older than the last bucket (or an unparseable/empty timestamp)
    }

    fun contacts(): List<Contact> = synchronized(lock) {
        contactsCache?.let { return it }
        val d = db ?: return emptyList()
        val sql = "SELECT from_address, to_address, updated_at FROM conversations WHERE ${statusNotIn(ConvStatusValue.discarded)}"
        val rows = mapAll(d, sql, emptyList()) { Triple(it.s(0), it.s(1), it.s(2)) }
        val buckets = recencyBuckets()
        val map = HashMap<String, Ranked>() // email → (name, total, score)
        fun add(raw: String, weight: Double) {
            for (e in MailAddress.parseList(raw)) {
                val email = e.email.lowercase()
                if (!email.contains("@")) continue
                val name = e.name.trim()
                val existing = map[email]
                if (existing != null) {
                    var nm = existing.name
                    if (name.contains(" ") && !nm.contains(" ")) nm = name
                    map[email] = Ranked(nm, existing.total + 1, existing.score + weight)
                } else {
                    map[email] = Ranked(if (name.isEmpty() || name.lowercase() == email) "" else name, 1, weight)
                }
            }
        }
        for ((from, to, updated) in rows) {
            val w = recencyWeight(updated, buckets)
            add(from, w); add(to, w)
        }
        // Rank by recency-weighted frequency, not lifetime volume — `total` stays the
        // honest raw count for the contacts list in Settings.
        val sorted = map.entries
            .sortedWith(compareByDescending<Map.Entry<String, Ranked>> { it.value.score }
                .thenByDescending { it.value.total })
            .map { Contact(it.key, it.value.name, it.value.total) }
        contactsCache = sorted
        sorted
    }

    // ── Calendar ──────────────────────────────────────────────────────────────

    fun upcomingEvents(fromISO: String, limit: Int = 200): List<CalendarEvent> = synchronized(lock) {
        val d = db ?: return emptyList()
        val sql = """
            SELECT $CAL_COLS FROM calendar_events ce JOIN calendars c ON c.key = ce.calendar_key
            WHERE ce.end_at >= ? AND ce.status != '${CalendarStatusValue.EVENT_CANCELLED}'
            ORDER BY ce.start_at ASC LIMIT ${maxOf(1, limit)}
        """.trimIndent()
        mapAll(d, sql, listOf(fromISO)) { mapEvent(it) }
    }

    fun event(key: String): CalendarEvent? = synchronized(lock) {
        val d = db ?: return null
        mapAll(d, "SELECT $CAL_COLS FROM calendar_events ce JOIN calendars c ON c.key = ce.calendar_key WHERE ce.key = ?", listOf(key)) { mapEvent(it) }.firstOrNull()
    }

    fun eventsBetween(fromISO: String, toISO: String, limit: Int = 1000): List<CalendarEvent> = synchronized(lock) {
        val d = db ?: return emptyList()
        val sql = """
            SELECT $CAL_COLS FROM calendar_events ce JOIN calendars c ON c.key = ce.calendar_key
            WHERE ce.start_at < ? AND ce.end_at >= ? AND ce.status != '${CalendarStatusValue.EVENT_CANCELLED}'
            ORDER BY ce.start_at ASC LIMIT ${maxOf(1, limit)}
        """.trimIndent()
        mapAll(d, sql, listOf(toISO, fromISO)) { mapEvent(it) }
    }

    /** Calendars a new event can actually be created on — see the iOS
     *  `writableCalendars` note: a visible read-only calendar (holidays,
     *  birthdays, a subscription) 403s every create. */
    fun writableCalendars(): List<WritableCalendar> = synchronized(lock) {
        val d = db ?: return emptyList()
        val sql = """
            SELECT account_key, provider_id, name, is_primary FROM calendars
            WHERE status = '${CalendarStatusValue.CALENDAR_ACTIVE}' AND is_visible = 1 AND provider_id IS NOT NULL
              AND IFNULL(is_writable, 1) = 1 AND IFNULL(is_owned, 1) = 1
            ORDER BY is_primary DESC, name ASC
        """.trimIndent()
        mapAll(d, sql, emptyList()) { WritableCalendar(it.s(0), it.s(1), it.s(2), it.getInt(3) == 1) }
    }

    // ── Conversation detail ─────────────────────────────────────────────────

    fun messages(conversationKey: String): List<Message> = synchronized(lock) {
        val d = db ?: return emptyList()
        val sql = """
            SELECT key, from_address, to_address, cc_address, subject, body_plain, body_html,
                   is_inbound, is_draft, created_at, sentiment_label, intent_label
            FROM messages WHERE conversation_key = ? ORDER BY created_at ASC
        """.trimIndent()
        mapAll(d, sql, listOf(conversationKey)) {
            Message(it.s(0), it.s(1), it.s(2), it.sn(3), it.s(4), it.sn(5), it.sn(6),
                it.getInt(7) == 1, it.getInt(8) == 1, it.s(9), it.sn(10), it.sn(11))
        }
    }

    // ── Mapping + helpers ───────────────────────────────────────────────────

    private fun mapConversation(c: Cursor) = Conversation(
        id = c.s(0), accountKey = c.s(1), fromAddress = c.s(3), toAddress = c.s(4),
        subject = c.s(2), snippet = c.s(6), status = c.s(5), unread = c.getInt(7) == 0,
        hasAttachment = c.getInt(8) == 1, priorityUrgent = c.getInt(9) == 1,
        priorityImportant = c.getInt(10) == 1, aiSummary = c.sn(11),
        triageLabel = c.sn(12), aiSummaryMedium = c.sn(13), aiSummaryShort = c.sn(14),
        createdAt = c.s(15), updatedAt = c.s(16), messageCount = c.getInt(17),
        triagePriority = if (c.isNull(18)) null else c.getDouble(18),
        dueOn = c.sn(19),
    )

    private fun mapEvent(c: Cursor) = CalendarEvent(
        id = c.s(0), accountKey = c.s(10),
        title = c.s(1).ifEmpty { "(No title)" }, startAt = c.s(2), endAt = c.s(3),
        allDay = c.getInt(4) == 1, location = c.sn(5), organizerName = c.sn(6),
        organizerEmail = c.sn(12), detail = c.sn(7), calendarColorHex = c.sn(8),
        calendarName = c.sn(9), metadataJSON = c.sn(11),
        calendarWritable = c.getInt(13) == 1,
    )

    private fun statusNotIn(statuses: List<String>, col: String = "status"): String =
        "$col NOT IN (${statuses.joinToString(", ") { "'$it'" }})"

    // ── MX mirror (docs/MX-Sync.md) ──────────────────────────────────────────
    //
    // inbox2-hosted mail the Rust engine keeps in the `mx_*` tables. Each row's
    // `payload` is the API's own JSON, so these return response-shaped strings and
    // the existing cloud models decode them — the caller can't tell the mirror from
    // the endpoint. Mirrors iOS `InboxStore+Mx.swift`. `null` = "can't answer this
    // locally", never "empty".
    //
    // Plain columns only: minSdk 26's system SQLite has no JSON functions, so
    // anything inside a payload is handled in Kotlin.

    /** The org if it is mirrored here for this user. `complete` also requires history
     *  to be fully read — a partial page would silently miss mail. */
    fun mxOrg(orgIdOrSlug: String, userKey: String, complete: Boolean = true): String? = synchronized(lock) {
        val d = db ?: return null
        val done = if (complete) "AND backfill_done = 1" else ""
        // Key-or-slug (iOS `mxOrg`, which matches `json_extract(payload, '$.slug')` in
        // SQL): the org's directory payload carries the slug, read here in Kotlin.
        val synced = mapAll(d, "SELECT organization_id FROM mx_sync_state WHERE user_key = ? $done",
            listOf(userKey)) { it.s(0) }
        synced.firstOrNull { it == orgIdOrSlug }
            ?: synced.firstOrNull { org -> payloadMatches(d, org, "organization", orgIdOrSlug, listOf("slug")) }
    }

    /** Directory rows of `type` for `org` whose payload has one of `fields` equal to
     *  `value` → their keys (the Kotlin stand-in for iOS's `json_extract` subselects). */
    private fun mxDirectoryKeysMatching(d: SQLiteDatabase, orgKey: String, type: String, value: String, fields: List<String>): List<String> =
        mapAll<String?>(d, "SELECT key, payload FROM mx_directory WHERE organization_id = ? AND type = ?", listOf(orgKey, type)) { c ->
            val payload = runCatching { JSONObject(c.s(1)) }.getOrNull()
            if (payload != null && fields.any { payload.optString(it) == value }) c.s(0) else null
        }.filterNotNull()

    private fun payloadMatches(d: SQLiteDatabase, orgKey: String, type: String, value: String, fields: List<String>): Boolean =
        mxDirectoryKeysMatching(d, orgKey, type, value, fields).isNotEmpty()

    /** `{"conversations":[…]}` — the org pool, newest first; no status hides
     *  trash / spam / archived, like the API. `domain` is a `dom_…` key, slug or name
     *  (iOS `mxConversations`). */
    /*  Callers don't page, so one page is as deep as the channel lists go (200). */
    fun mxConversationsJson(org: String, status: String?, read: Boolean?, domain: String?, page: Int = 1, perPage: Int = 200, labeledOnly: Boolean = false): String = synchronized(lock) {
        val d = db ?: return "{\"conversations\":[]}"
        val conditions = mutableListOf("organization_id = ?")
        val binds = mutableListOf(org)
        if (status != null) { conditions.add("status = ?"); binds.add(status) }
        else {
            conditions.add("status NOT IN ('trash', 'spam', 'archived')")
            // The Inbox skips sent-only threads; Lore's Waiting list needs them.
            if (!labeledOnly) conditions.add("COALESCE(json_extract(payload, '$.sent_only'), 0) = 0")
        }
        if (read != null) { conditions.add("read = ?"); binds.add(if (read) "1" else "0") }
        // Lore: label-filter before paging, so old labelled threads aren't paged out.
        if (labeledOnly) conditions.add("json_extract(payload, '$.triage_label') IS NOT NULL AND json_extract(payload, '$.triage_label') != 'resolved'")
        if (domain != null) {
            val keys = listOf(domain) + mxDirectoryKeysMatching(d, org, "domains", domain, listOf("slug", "name"))
            conditions.add("domain_key IN (${keys.joinToString(", ") { "?" }})"); binds.addAll(keys)
        }
        val sql = """
            SELECT payload FROM mx_conversations WHERE ${conditions.joinToString(" AND ")}
            ORDER BY updated_at DESC, key DESC LIMIT $perPage OFFSET ${maxOf(page - 1, 0) * perPage}
        """.trimIndent()
        // Payloads are already JSON: splice them rather than parse and re-encode.
        mapAll(d, sql, binds) { it.s(0) }.joinToString(",", "{\"conversations\":[", "]}")
    }

    /** Opened sealed mail keeps ciphertext in `payload` and its text in `plain`: put
     *  the text in the fields the API would have filled. */
    private fun withOpenedText(payload: String, plain: String): JSONObject? {
        val message = runCatching { JSONObject(payload) }.getOrNull() ?: return null
        val opened = plain.takeIf { it.isNotEmpty() }?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return message
        val header = opened.optJSONObject("header") ?: JSONObject()
        val body = opened.optJSONObject("body") ?: JSONObject()
        listOf("subject" to header.optString("subject"), "from_address" to header.optString("from"),
            "to_address" to header.optString("to"), "cc_address" to header.optString("cc"),
            "body_plain" to body.optString("plain"), "body_html" to body.optString("html"),
        ).forEach { (name, value) -> if (value.isNotEmpty()) message.put(name, value) }
        message.put("body_plain", body.optString("plain")) // an empty mail is opened, not locked
        return message
    }

    /** `{"conversation":{…,"messages":[…],"notes":[…]}}` for a thread whose children
     *  are all here; null for one held only as a list row. */
    fun mxConversationDetailJson(org: String, id: String): String? = synchronized(lock) {
        val d = db ?: return null
        val row = mapAll(d, "SELECT payload FROM mx_conversations WHERE key = ? AND organization_id = ? AND hydrated = 1",
            listOf(id, org)) { it.s(0) }.firstOrNull() ?: return null
        val conversation = runCatching { JSONObject(row) }.getOrNull() ?: return null
        fun children(table: String) = JSONArray(
            mapAll(d, "SELECT payload FROM $table WHERE conversation_key = ? ORDER BY created_at ASC, key ASC", listOf(id)) { it.s(0) }
                .mapNotNull { runCatching { JSONObject(it) }.getOrNull() })
        conversation.put("messages", JSONArray(
            mapAll(d, "SELECT payload, COALESCE(plain, '') FROM mx_messages WHERE conversation_key = ? ORDER BY created_at ASC, key ASC", listOf(id)) {
                withOpenedText(it.s(0), it.s(1))
            }.filterNotNull()))
        conversation.put("notes", children("mx_notes"))
        // The list row names assignees compactly; the detail endpoint returns the full
        // member. Same people — take the richer record from the mirrored directory.
        val members = mapAll(d, "SELECT key, payload FROM mx_directory WHERE organization_id = ? AND type = 'members'", listOf(org)) {
            it.s(0) to it.s(1)
        }.toMap()
        conversation.optJSONArray("assignees")?.let { compact ->
            val full = JSONArray()
            for (i in 0 until compact.length()) {
                val a = compact.optJSONObject(i) ?: continue
                full.put(members[a.optString("id")]?.let { runCatching { JSONObject(it) }.getOrNull() } ?: a)
            }
            conversation.put("assignees", full)
        }
        JSONObject().put("conversation", conversation).toString()
    }

    /** `{"<type>":[…]}` — a directory listing (`tags`, `members`, …) exactly as its
     *  index endpoint returned it, in the server's order. */
    fun mxDirectoryJson(org: String, type: String): String = synchronized(lock) {
        val d = db ?: return "{\"$type\":[]}"
        mapAll(d, "SELECT payload FROM mx_directory WHERE organization_id = ? AND type = ? ORDER BY position", listOf(org, type)) { it.s(0) }
            .joinToString(",", "{\"$type\":[", "]}")
    }

    private fun <T> mapAll(d: SQLiteDatabase, sql: String, binds: List<String>, map: (Cursor) -> T): List<T> {
        val out = ArrayList<T>()
        runCatching {
            d.rawQuery(sql, binds.toTypedArray()).use { c -> while (c.moveToNext()) out.add(map(c)) }
        }.onFailure { lastReadError = it.message ?: it.toString(); Log.e(TAG, "query failed: ${it.message}\n$sql") }
        return out
    }

    private fun Cursor.s(i: Int): String = if (isNull(i)) "" else getString(i) ?: ""
    private fun Cursor.sn(i: Int): String? = if (isNull(i)) null else getString(i)?.takeIf { it.isNotEmpty() }

    companion object {
        private const val TAG = "com.inbox2.store"
        private const val CONV_COLS =
            "key, organization_id, subject, from_address, to_address, status, snippet, " +
            "read, has_attachment, priority_urgent, priority_important, ai_summary, " +
            "triage_label, ai_summary_medium, ai_summary_short, " +
            "created_at, updated_at, " +
            "(SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = conversations.key) AS message_count, " +
            "triage_priority, next_action_due_on"
        private const val CONV_COLS_C =
            "c.key, c.organization_id, c.subject, c.from_address, c.to_address, c.status, c.snippet, " +
            "c.read, c.has_attachment, c.priority_urgent, c.priority_important, c.ai_summary, " +
            "c.triage_label, c.ai_summary_medium, c.ai_summary_short, " +
            "c.created_at, c.updated_at, " +
            "(SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = c.key) AS message_count, " +
            "c.triage_priority, c.next_action_due_on"
        private const val CAL_COLS =
            "ce.key, ce.title, ce.start_at, ce.end_at, ce.all_day, ce.location, " +
            "ce.organizer_name, ce.description, c.color, c.name, ce.account_key, " +
            "ce.metadata, ce.organizer_email, c.is_writable"
    }
}
