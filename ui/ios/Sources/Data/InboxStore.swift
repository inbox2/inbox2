import Foundation
import SQLite3

/// Read-only access to the local `inbox2.db`, mirroring the desktop frontend's
/// SQLite read path (`lib/db.js`, `hooks/useInboxConversations.js`,
/// `lib/conversationDetail.js`). On both platforms the UI reads conversations
/// straight from SQLite and only *writes* through the Rust engine — this keeps that
/// same split on iOS (writes go through `InboxEngine.perform_action`).
///
/// The same file the Rust `SyncEngine` opens for writes is opened here read-only,
/// so reads always reflect the latest sync/write-back the engine has committed.
/// We re-query on engine events rather than holding cached rows.
final class InboxStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let path: String
    // SQLite handle isn't safe to share across threads; serialize all access.
    let queue = DispatchQueue(label: "com.inbox2.store")
    /// Set by `run` (within `queue`) when a read fails with a real error — disk I/O,
    /// corruption, etc. — so a failed read can be told apart from an empty result. The
    /// `load` entry point snapshots it atomically; it's not just "no rows".
    private var runError: String?

    /// SQLITE_TRANSIENT tells SQLite to copy bound strings (Swift Strings are not
    /// stable past the bind call).
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(dbPath: String) {
        self.path = dbPath
        open()
    }

    deinit { if let db { sqlite3_close(db) } }

    private func open() {
        // Open read-write (SELECT-only from here) + no-mutex (we serialize via
        // `queue`). The engine writes this same WAL database from its own
        // connection; a second in-process connection is the normal WAL pattern and
        // — unlike a read-only handle — never trips on shared-memory setup, so our
        // reads always see the engine's committed writes. If the file doesn't exist
        // yet (no account connected) the open fails quietly and reads return [].
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        if rc == SQLITE_OK {
            // Wait rather than erroring if the engine holds a write lock.
            sqlite3_busy_timeout(db, 3000)
            Log.store.info("opened local store at \(self.path, privacy: .public)")
        } else {
            Log.store.error("failed to open store (rc=\(rc)) at \(self.path, privacy: .public) — empty until an account syncs")
            if db != nil { sqlite3_close(db); db = nil }
        }
    }

    /// Reopen if the file appeared after init (first sync creates it).
    func reopenIfNeeded() {
        queue.sync {
            if db == nil { open() }
        }
    }

    /// Run a read off the calling actor (on a background thread; the store still
    /// serializes internally via `queue`). Lets views load data without blocking the
    /// main thread — e.g. so tab switches stay smooth. The returned value is handed
    /// back on the awaiting context's actor.
    func read<T: Sendable>(_ body: @escaping @Sendable (InboxStore) -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: body(self))
            }
        }
    }

    // MARK: - Conversations

    /// Inbox list for a channel. `accountKey == nil` is the unified inbox (all
    /// accounts); otherwise scoped to one external account. Mirrors the desktop
    /// base query: hide trash/spam/archived, newest first, capped at 200.
    func conversations(accountKey: String?, folder: MailFolder = .inbox, filter: InboxFilter, query: String) -> [Conversation] {
        load(accountKey: accountKey, folder: folder, filter: filter, query: query).conversations
    }

    /// Result of an inbox-list read: the rows plus any disk/read failure, so the UI can
    /// tell a genuinely-empty mailbox apart from a read that errored (and show that
    /// instead of the misleading "All clear" empty state).
    struct InboxLoad: Sendable {
        let conversations: [Conversation]
        /// Non-nil when the SQLite read failed (disk I/O, corruption, can't-open, …).
        /// The raw engine message — the view turns it into an error state.
        let diskError: String?
    }

    /// Inbox-list read that also reports a disk/read failure. The query runs and the
    /// error is captured inside one `queue.sync`, so the two can't be torn apart by a
    /// concurrent read.
    /// `labeledOnly` (Lore): only triage-labelled threads, up to `limit` of them, so an
    /// old open Lore task isn't pushed out by the 200 newest inbox rows.
    func load(accountKey: String?, folder: MailFolder = .inbox, filter: InboxFilter, query: String,
              labeledOnly: Bool = false, limit: Int = 200) -> InboxLoad {
        queue.sync {
            runError = nil
            let rows = labeledOnly && query.isEmpty
                ? loreLocked(folder: folder, limit: limit)
                : conversationsLocked(accountKey: accountKey, folder: folder, filter: filter, query: query)
            return InboxLoad(conversations: rows, diskError: runError)
        }
    }

    /// Lore's local read: labelled inbox threads (Today) or archived ones (History). Caller holds `queue`.
    private func loreLocked(folder: MailFolder, limit: Int) -> [Conversation] {
        guard db != nil else { return [] }
        if folder == .inbox { return inboxQuery(accountKey: nil, filter: .all, labeledOnly: true, limit: limit) }
        return run("""
            SELECT \(Self.convCols) FROM conversations
            WHERE status = '\(ConvStatusValue.archived)' AND triage_label IS NOT NULL AND triage_label <> 'resolved'
            ORDER BY updated_at DESC LIMIT \(limit)
            """, binds: [], mapConversation)
    }

    /// The folder/query → rows logic. Caller holds `queue`.
    private func conversationsLocked(accountKey: String?, folder: MailFolder, filter: InboxFilter, query: String) -> [Conversation] {
            guard db != nil else { return [] }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            // A search query routes through FTS5 (full-text over subject/body/from/
            // to), across all folders; an empty query is the folder list.
            if !trimmed.isEmpty {
                return searchFTS(accountKey: accountKey, filter: filter, query: trimmed)
            }
            // Triaged is a cross-folder view (like the desktop priority filter): any
            // conversation assigned an Eisenhower quadrant, archived included.
            if filter == .triaged {
                return triagedConversations(accountKey: accountKey)
            }
            // Triage = an inbox2/* gmail label; Sent / Drafts are provider folders
            // (orthogonal to our status model) — all need a join, not a status.
            if let label = folder.triageLabel {
                return triageQuery(accountKey: accountKey, label: label, filter: filter)
            }
            // Meta channel sub-views narrow the conversation list by `kind`
            // (All = no narrow). Same status/unread treatment as the base inbox.
            if folder.isMeta {
                return metaQuery(accountKey: accountKey, kinds: folder.metaKinds, filter: filter)
            }
            switch folder {
            case .sent: return folderRoleQuery(accountKey: accountKey, role: "sent", filter: filter)
            case .drafts: return draftsQuery(accountKey: accountKey)
            case .inbox: return inboxQuery(accountKey: accountKey, filter: filter)
            default: break   // archive / trash → status below
            }

            // Archive / Trash map directly to our conversation status.
            var conditions: [String]
            switch folder {
            case .archive: conditions = ["status = '\(ConvStatusValue.archived)'"]
            case .spam: conditions = ["status = '\(ConvStatusValue.spam)'"]
            case .trash: conditions = ["status = '\(ConvStatusValue.trash)'"]
            default: conditions = [statusNotIn(ConvStatusValue.inboxHidden)]
            }
            var binds: [String] = []
            if let accountKey {
                conditions.append("organization_id = ?\(binds.count + 1)")
                binds.append(accountKey)
            }
            if filter == .unread { conditions.append("read = 0") }

            let sql = """
            SELECT \(Self.convCols)
            FROM conversations
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY updated_at DESC LIMIT 200
            """
            let rows = run(sql, binds: binds, mapConversation)
            Log.store.info("loaded \(rows.count) conversations (channel=\(accountKey ?? "unified", privacy: .public) folder=\(folder.rawValue, privacy: .public) filter=\(String(describing: filter), privacy: .public))")
            return rows
    }

    /// The real Inbox: conversations with a message currently in the provider's
    /// inbox folder/label (Microsoft/IMAP: `well_known_role = 'inbox'`; Gmail: an
    /// "INBOX" label) and a non-hidden status. Mirrors the desktop `useUnifiedInbox`
    /// query — a status filter alone lets sent/archived-on-server mail leak in.
    /// Caller holds `queue`.
    private func inboxQuery(accountKey: String?, filter: InboxFilter, labeledOnly: Bool = false, limit: Int = 200) -> [Conversation] {
        var conditions = [
            statusNotIn(ConvStatusValue.inboxHidden, col: "c.status"),
        ]
        if labeledOnly { conditions.append("c.triage_label IS NOT NULL AND c.triage_label <> 'resolved'") }   // resolved isn't Lore work
        var binds: [String] = []
        if let accountKey {
            conditions.append("c.organization_id = ?\(binds.count + 1)")
            binds.append(accountKey)
        }
        if filter == .unread { conditions.append("c.read = 0") }
        // Drive inbox membership from the indexed (account_key, folder_key) inbox
        // set, NOT a JOIN/scan over every message. Every inbox message reliably
        // carries an mps row whose folder_key is the inbox folder (verified across
        // Gmail/MS/IMAP — the labels-LIKE alternative finds nothing folder_key
        // doesn't), so we avoid both the unindexable `labels LIKE` and the
        // JOIN+DISTINCT row-explosion. For a large archived account this is the
        // difference between scanning all its conversations (~2s) and reading the
        // small inbox set. Bind accountKey again for the folder filter so we don't
        // rely on positional-parameter reuse.
        var folderAccountClause = ""
        if let accountKey {
            binds.append(accountKey)
            folderAccountClause = " AND f.account_key = ?\(binds.count)"
        }
        let sql = """
        SELECT \(Self.convColsC)
        FROM conversations c
        WHERE \(conditions.joined(separator: " AND "))
          AND c.key IN (
            SELECT m.conversation_key FROM message_provider_state mps
            JOIN messages m ON m.key = mps.message_key
            WHERE mps.folder_key IN (
              SELECT f.key FROM external_folders f
              WHERE f.well_known_role = 'inbox'\(folderAccountClause)
            )
          )
        ORDER BY c.updated_at DESC LIMIT \(limit)
        """
        let rows = run(sql, binds: binds, mapConversation)
        Log.store.info("loaded \(rows.count) inbox conversation(s) (channel=\(accountKey ?? "unified", privacy: .public) filter=\(String(describing: filter), privacy: .public))")
        return rows
    }

    /// Conversations with a message in a provider folder of the given well-known
    /// role (e.g. "sent"). Caller holds `queue`.
    private func folderRoleQuery(accountKey: String?, role: String, filter: InboxFilter) -> [Conversation] {
        var conditions = ["f.well_known_role = ?1"]
        var binds = [role]
        if let accountKey {
            conditions.append("c.organization_id = ?\(binds.count + 1)")
            binds.append(accountKey)
        }
        if filter == .unread { conditions.append("c.read = 0") }
        let sql = """
        SELECT DISTINCT \(Self.convColsC)
        FROM conversations c
        JOIN messages m ON m.conversation_key = c.key
        JOIN message_provider_state mps ON mps.message_key = m.key
        JOIN external_folders f ON f.key = mps.folder_key
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY c.updated_at DESC LIMIT 200
        """
        let rows = run(sql, binds: binds, mapConversation)
        Log.store.info("loaded \(rows.count) conversation(s) in folder role=\(role, privacy: .public)")
        return rows
    }

    /// Meta channel sub-view: conversations narrowed by `kind` (nil = all), scoped
    /// to the account, hiding trash/spam/archived. Mirrors the desktop channel/kind
    /// sub-views. Caller holds `queue`.
    private func metaQuery(accountKey: String?, kinds: [String]?, filter: InboxFilter) -> [Conversation] {
        var conditions = [statusNotIn(ConvStatusValue.inboxHidden)]
        var binds: [String] = []
        if let accountKey {
            conditions.append("organization_id = ?\(binds.count + 1)")
            binds.append(accountKey)
        }
        if let kinds, !kinds.isEmpty {
            let start = binds.count + 1
            let placeholders = kinds.indices.map { "?\(start + $0)" }.joined(separator: ", ")
            conditions.append("kind IN (\(placeholders))")
            binds.append(contentsOf: kinds)
        }
        if filter == .unread { conditions.append("read = 0") }
        let sql = """
        SELECT \(Self.convCols)
        FROM conversations
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY updated_at DESC LIMIT 200
        """
        let rows = run(sql, binds: binds, mapConversation)
        Log.store.info("loaded \(rows.count) meta conversation(s) (kinds=\(kinds ?? ["all"], privacy: .public))")
        return rows
    }

    /// Conversations tagged with an inbox2 triage/quadrant gmail label (e.g.
    /// "inbox2/Priority"). The per-account gmail label id (e.g. Label_23) is derived
    /// from the external_folders key suffix and matched against the message's
    /// labels array. Caller holds `queue`.
    private func triageQuery(accountKey: String?, label: String, filter: InboxFilter) -> [Conversation] {
        var conditions = [
            "f.provider_name = ?1",
            "mps.labels LIKE '%' || replace(substr(f.key, instr(f.key, '_label_') + 1), 'label_', 'Label_') || '%'",
            statusNotIn(ConvStatusValue.discarded, col: "c.status"),
        ]
        var binds = [label]
        if let accountKey {
            conditions.append("c.organization_id = ?\(binds.count + 1)")
            binds.append(accountKey)
        }
        if filter == .unread { conditions.append("c.read = 0") }
        let sql = """
        SELECT DISTINCT \(Self.convColsC)
        FROM conversations c
        JOIN messages m ON m.conversation_key = c.key
        JOIN message_provider_state mps ON mps.message_key = m.key AND mps.account_key = c.organization_id
        JOIN external_folders f ON f.account_key = c.organization_id
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY c.updated_at DESC LIMIT 200
        """
        let rows = run(sql, binds: binds, mapConversation)
        Log.store.info("loaded \(rows.count) conversation(s) in triage \(label, privacy: .public)")
        return rows
    }

    /// Conversations with a draft message.
    private func draftsQuery(accountKey: String?) -> [Conversation] {
        var conditions = ["m.is_draft = 1"]
        var binds: [String] = []
        if let accountKey {
            conditions.append("c.organization_id = ?\(binds.count + 1)")
            binds.append(accountKey)
        }
        let sql = """
        SELECT DISTINCT \(Self.convColsC)
        FROM conversations c
        JOIN messages m ON m.conversation_key = c.key
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY c.updated_at DESC LIMIT 200
        """
        let rows = run(sql, binds: binds, mapConversation)
        Log.store.info("loaded \(rows.count) draft conversation(s)")
        return rows
    }

    /// Triaged conversations across folders (archived included; only trash/spam
    /// excluded): any thread assigned an Eisenhower quadrant, i.e. urgent and/or
    /// important — mirrors the desktop `triaged = urgent || important`. Caller holds
    /// `queue`.
    private func triagedConversations(accountKey: String?) -> [Conversation] {
        var conditions = [statusNotIn(ConvStatusValue.discarded),
                          "(priority_urgent = 1 OR priority_important = 1)"]
        var binds: [String] = []
        if let accountKey {
            conditions.append("organization_id = ?1")
            binds.append(accountKey)
        }
        let sql = """
        SELECT \(Self.convCols)
        FROM conversations
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY updated_at DESC LIMIT 200
        """
        let rows = run(sql, binds: binds, mapConversation)
        Log.store.info("loaded \(rows.count) triaged conversation(s) (channel=\(accountKey ?? "unified", privacy: .public))")
        return rows
    }

    /// Full-text search via the engine-maintained `messages_fts` FTS5 table,
    /// mirroring the desktop SearchResultsView query. Scoped to the channel (nil =
    /// all accounts); search shows archived mail too (only trash/spam excluded),
    /// matching the desktop's search semantics. Caller holds `queue`.
    private func searchFTS(accountKey: String?, filter: InboxFilter, query: String) -> [Conversation] {
        let match = buildFtsMatch(query)
        guard !match.isEmpty else { return [] }
        var conditions = ["messages_fts MATCH ?1", statusNotIn(ConvStatusValue.discarded, col: "c.status")]
        var binds = [match]
        if let accountKey {
            conditions.append("c.organization_id = ?\(binds.count + 1)")
            binds.append(accountKey)
        }
        if let clause = Self.filterClause(filter) { conditions.append(clause) }
        let sql = """
        SELECT DISTINCT \(Self.convColsC)
        FROM messages_fts fts
        JOIN messages m ON m.rowid = fts.rowid
        JOIN conversations c ON c.key = m.conversation_key
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY c.updated_at DESC LIMIT 100
        """
        let rows = run(sql, binds: binds, mapConversation)
        Log.store.info("FTS search '\(query)' (match=\(match)) → \(rows.count) hit(s)")
        return rows
    }

    /// Build a safe FTS5 MATCH expression, mirroring the desktop `buildFtsMatch`:
    /// bare terms are ANDed, `or`/`and` are operators, "quoted" is a phrase, every
    /// term is quoted so FTS5 specials can't break it. The final term gets a `*`
    /// prefix so incremental typing matches ("ali" → "alibaba"). Returns "" when
    /// nothing is searchable.
    /// The Unread/Triaged pill as a WHERE condition (nil for All), shared by the
    /// FTS search and the provider hits merged into it.
    static func filterClause(_ filter: InboxFilter) -> String? {
        switch filter {
        case .all: nil
        case .unread: "c.read = 0"
        case .triaged: "(c.priority_urgent = 1 OR c.priority_important = 1)"
        }
    }

    /// Whether the query names anything to look for (exclusions alone don't).
    func hasSearchTerms(_ query: String) -> Bool { !buildFtsMatch(query).isEmpty }

    private func buildFtsMatch(_ query: String) -> String {
        let tokens: [String] = {
            guard let re = try? NSRegularExpression(pattern: "-?\"[^\"]*\"|\\S+") else { return [] }
            let ns = query as NSString
            return re.matches(in: query, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }()
        var parts: [String] = []
        var excluded: [String] = []
        for tok in tokens {
            // `-word` / `-"a phrase"` excludes. Quoted as a term it would REQUIRE the
            // word instead (the tokenizer drops the dash).
            if tok.count > 1 && tok.hasPrefix("-") {
                let inner = tok.dropFirst().replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { excluded.append("\"\(inner)\"") }
                continue
            }
            let upper = tok.uppercased()
            if upper == "OR" || upper == "AND" {
                guard let prev = parts.last, prev != "OR", prev != "AND" else { continue }
                parts.append(upper)
                continue
            }
            var inner = tok
            if inner.hasPrefix("\"") && inner.hasSuffix("\"") && inner.count >= 2 { inner = String(inner.dropFirst().dropLast()) }
            inner = inner.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { parts.append("\"\(inner)\"") }
        }
        while let last = parts.last, last == "OR" || last == "AND" { parts.removeLast() }
        guard !parts.isEmpty else { return "" }
        // Prefix-match the final phrase token for incremental search.
        if let last = parts.last, last.hasPrefix("\"") { parts[parts.count - 1] = last + "*" }
        // FTS5 NOT is binary, so exclusions trail the bracketed rest (an OR in it
        // can't let excluded mail back in).
        guard !excluded.isEmpty else { return parts.joined(separator: " ") }
        return "(\(parts.joined(separator: " "))) NOT " + excluded.joined(separator: " NOT ")
    }

    /// The 21-column conversation projection every list query SELECTs — the column
    /// order is what `mapConversation` reads by index, so it lives in one place
    /// (mirrors Android's `CONV_COLS`). `convColsC` is the alias-qualified variant
    /// for queries that join from `conversations c`.
    private static let convCols = """
        key, organization_id, subject, from_address, to_address, status, snippet,
        read, has_attachment, priority_urgent, priority_important, ai_summary,
        triage_label, ai_summary_medium, ai_summary_short,
        created_at, updated_at,
        (SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = conversations.key) AS message_count,
        (SELECT MAX(mo.created_at) FROM messages mo
            JOIN message_provider_state mpo ON mpo.message_key = mo.key
            JOIN external_folders fo ON fo.key = mpo.folder_key
            WHERE mo.conversation_key = conversations.key AND fo.well_known_role = 'sent') AS sent_at,
        triage_priority, next_action_due_on
        """
    private static let convColsC = """
        c.key, c.organization_id, c.subject, c.from_address, c.to_address, c.status, c.snippet,
        c.read, c.has_attachment, c.priority_urgent, c.priority_important, c.ai_summary,
        c.triage_label, c.ai_summary_medium, c.ai_summary_short,
        c.created_at, c.updated_at,
        (SELECT COUNT(*) FROM messages mc WHERE mc.conversation_key = c.key) AS message_count,
        (SELECT MAX(mo.created_at) FROM messages mo
            JOIN message_provider_state mpo ON mpo.message_key = mo.key
            JOIN external_folders fo ON fo.key = mpo.folder_key
            WHERE mo.conversation_key = c.key AND fo.well_known_role = 'sent') AS sent_at,
        c.triage_priority, c.next_action_due_on
        """

    /// Map a conversation row — every caller SELECTs `convCols`/`convColsC`, so the
    /// indices here are the single pairing with that projection.
    private func mapConversation(_ stmt: OpaquePointer) -> Conversation {
        Conversation(
            id: text(stmt, 0),
            accountKey: text(stmt, 1),
            fromAddress: text(stmt, 3),
            toAddress: text(stmt, 4),
            subject: text(stmt, 2),
            snippet: text(stmt, 6),
            status: text(stmt, 5),
            unread: sqlite3_column_int(stmt, 7) == 0,
            hasAttachment: sqlite3_column_int(stmt, 8) == 1,
            priorityUrgent: sqlite3_column_int(stmt, 9) == 1,
            priorityImportant: sqlite3_column_int(stmt, 10) == 1,
            aiSummary: textOrNil(stmt, 11),
            triageLabel: textOrNil(stmt, 12),
            aiSummaryMedium: textOrNil(stmt, 13),
            aiSummaryShort: textOrNil(stmt, 14),
            createdAt: text(stmt, 15),
            updatedAt: text(stmt, 16),
            messageCount: Int(sqlite3_column_int(stmt, 17)),
            sentAt: textOrNil(stmt, 18),
            triagePriority: doubleOrNil(stmt, 19),
            dueOn: textOrNil(stmt, 20)
        )
    }

    /// Unread count for the app-icon badge (nil = unified). MUST match what the
    /// Inbox actually shows, so it uses the same provider-INBOX join as
    /// `inboxQuery` (not a bare status filter) — otherwise open+unread threads that
    /// aren't in the provider inbox (server-side moved/archived, or Meta channels
    /// shown only in their own sub-views) inflate the badge while the inbox reads 0.
    func unreadCount(accountKey: String?) -> Int {
        queue.sync {
            guard db != nil else { return 0 }
            var conditions = [
                statusNotIn(ConvStatusValue.inboxHidden, col: "c.status"),
                "c.read = 0",
            ]
            var binds: [String] = []
            if let accountKey {
                conditions.append("c.organization_id = ?\(binds.count + 1)")
                binds.append(accountKey)
            }
            // Drive from unread conversations + EXISTS, not a JOIN through
            // message_provider_state: the join form full-SCANs provider-state
            // (which archive/All-Mail sync grew to tens of thousands of rows),
            // costing seconds for the unified badge regardless of unread count.
            // EXISTS short-circuits at the first inbox message.
            //
            // Membership MUST match `inboxQuery` (the list the user sees) or the
            // badge phantoms over an empty inbox: a `labels LIKE '%"INBOX"%'` OR
            // branch here once counted conversations whose label-blob still held
            // "INBOX" after they left the inbox folder — rows the list never shows.
            // The inbox-folder set alone is complete (see inboxQuery), so key off it.
            let sql = """
            SELECT COUNT(*)
            FROM conversations c
            WHERE \(conditions.joined(separator: " AND "))
              AND EXISTS (
                SELECT 1 FROM messages m
                JOIN message_provider_state mps ON mps.message_key = m.key
                JOIN external_folders ef ON ef.key = mps.folder_key AND ef.account_key = c.organization_id
                WHERE m.conversation_key = c.key
                  AND ef.well_known_role = 'inbox'
              )
            """
            let rows = run(sql, binds: binds) { Int(sqlite3_column_int($0, 0)) }
            return rows.first ?? 0
        }
    }

    /// Load a single conversation by key (e.g. to open from the Activity feed or a
    /// notification). Reuses the same projection as the list query.
    /// The ids other devices of this mailbox may tag this thread with: the
    /// mailbox address plus its provider thread id, and plus every message's
    /// Message-ID (brackets trimmed).
    /// Mirrors `SyncStore::notification_tag_id` in the Rust core; hashed by
    /// `NotificationManager.notificationTag`.
    func notificationTagIds(conversationKey key: String) -> [String] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT lower(a.email_address) || ':' || c.provider_thread_id
              FROM conversations c
              JOIN messages m ON m.conversation_key = c.key
              JOIN external_accounts a ON a.key = m.account_key
             WHERE c.key = ?1 AND IFNULL(c.provider_thread_id, '') != ''
            UNION
            SELECT lower(a.email_address) || ':' || trim(m.message_id_header, '<> ')
              FROM messages m JOIN external_accounts a ON a.key = m.account_key
             WHERE m.conversation_key = ?1 AND trim(IFNULL(m.message_id_header, ''), '<> ') != ''
            """
            return run(sql, binds: [key]) { text($0, 0) }
        }
    }

    func conversation(key: String) -> Conversation? {
        queue.sync {
            guard db != nil else { return nil }
            let sql = """
            SELECT \(Self.convCols),
                   (ai_meta_msg_key IS NOT NULL AND ai_meta_msg_key = (
                        SELECT m.key FROM messages m WHERE m.conversation_key = conversations.key
                        ORDER BY m.created_at DESC LIMIT 1)) AS summaries_current
            FROM conversations WHERE key = ?1 LIMIT 1
            """
            return run(sql, binds: [key]) { stmt in
                var c = mapConversation(stmt)
                c.summariesCurrent = sqlite3_column_int(stmt, 20) == 1
                return c
            }.first
        }
    }

    /// Recent inbound mail across all accounts — the Activity feed. Newest first,
    /// excluding discarded (trash/spam) threads.
    func recentActivity(limit: Int = 40) -> [ActivityEntry] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT m.key, m.from_address, m.created_at, m.conversation_key, c.subject, c.read
            FROM messages m
            JOIN conversations c ON c.key = m.conversation_key
            WHERE m.is_inbound = 1 AND \(statusNotIn(ConvStatusValue.discarded, col: "c.status"))
            ORDER BY m.created_at DESC LIMIT ?1
            """
            let rows = run(sql, binds: ["\(limit)"]) { stmt in
                ActivityEntry(
                    id: text(stmt, 0),
                    fromAddress: text(stmt, 1),
                    createdAt: text(stmt, 2),
                    conversationKey: text(stmt, 3),
                    subject: text(stmt, 4),
                    unread: sqlite3_column_int(stmt, 5) == 0
                )
            }
            Log.store.info("loaded \(rows.count) activity entries")
            return rows
        }
    }

    // MARK: - Local rules & agents (read-only; managed on desktop)

    /// The on-device auto-rules (local_rules). Read-only on iOS.
    func localRules() -> [LocalRule] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = "SELECT key, name, conditions, action, enabled, account_key FROM local_rules ORDER BY created_at DESC"
            let rows = run(sql, binds: []) { stmt in
                LocalRule(key: text(stmt, 0), name: text(stmt, 1), conditionsJSON: text(stmt, 2),
                          actionJSON: text(stmt, 3), enabled: sqlite3_column_int(stmt, 4) == 1,
                          accountKey: textOrNil(stmt, 5))
            }
            Log.store.info("loaded \(rows.count) local rule(s)")
            return rows
        }
    }

    /// The installed CLI agents (local_agents) the rules can dispatch to.
    func localAgents() -> [LocalAgent] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = "SELECT display_name, adapter_id, version, enabled FROM local_agents ORDER BY enabled DESC, display_name"
            return run(sql, binds: []) { stmt in
                LocalAgent(displayName: text(stmt, 0), adapterId: text(stmt, 1),
                           version: textOrNil(stmt, 2), enabled: sqlite3_column_int(stmt, 3) == 1)
            }
        }
    }

    // MARK: - Outbox

    /// The actionable send queue — `outbox_messages` rows not yet delivered
    /// (pending / sending / failed), newest first. The engine auto-retries pending
    /// rows; `failed` rows have exhausted `max_retries` and need a manual nudge.
    /// Conversation rows for keys a provider-side search returned (Gmail/Outlook
    /// read inside attachments; local FTS doesn't). Trashed/discarded stay out,
    /// like the FTS search.
    func conversations(keys: [String], filter: InboxFilter = .all) -> [Conversation] {
        queue.sync {
            guard db != nil, !keys.isEmpty,
                  let json = try? JSONSerialization.data(withJSONObject: keys),
                  let list = String(data: json, encoding: .utf8) else { return [] }
            let sql = """
            SELECT \(Self.convColsC) FROM conversations c
            WHERE c.key IN (SELECT value FROM json_each(?1))
              AND \(statusNotIn(ConvStatusValue.discarded, col: "c.status"))
              \(Self.filterClause(filter).map { "AND \($0)" } ?? "")
            """
            return run(sql, binds: [list], mapConversation)
        }
    }

    func outboxMessages() -> [OutboxItem] {
        queue.sync {
            guard db != nil else { return [] }
            let placeholders = OutboxStatusValue.queued.map { "'\($0)'" }.joined(separator: ",")
            let sql = """
                SELECT key, account_key, payload, status, retry_count, max_retries,
                       error_message, created_at
                FROM outbox_messages
                WHERE status IN (\(placeholders))
                ORDER BY created_at DESC
                """
            let rows = run(sql, binds: []) { stmt in
                OutboxItem(key: self.text(stmt, 0), accountKey: self.text(stmt, 1),
                           payloadJSON: self.text(stmt, 2), status: self.text(stmt, 3),
                           retryCount: Int(sqlite3_column_int(stmt, 4)),
                           maxRetries: Int(sqlite3_column_int(stmt, 5)),
                           errorMessage: self.textOrNil(stmt, 6), createdAt: self.text(stmt, 7))
            }
            Log.store.info("loaded \(rows.count) outbox item(s)")
            return rows
        }
    }

    // MARK: - Contacts

    private var contactsCache: [Contact]?

    /// Deduplicated recipient suggestions derived from from/to addresses across all
    /// non-discarded conversations, ranked by recency-weighted frequency
    /// (`ContactRanking`). Computed once and cached.
    func contacts() -> [Contact] {
        queue.sync {
            if let c = contactsCache { return c }
            guard db != nil else { return [] }
            let sql = "SELECT from_address, to_address, updated_at FROM conversations WHERE \(statusNotIn(ConvStatusValue.discarded))"
            let rows = run(sql, binds: []) { stmt in
                (from: self.text(stmt, 0), to: self.text(stmt, 1), updatedAt: self.text(stmt, 2))
            }
            let sorted = ContactRanking.rank(rows)
            contactsCache = sorted
            Log.store.info("derived \(sorted.count) contacts for autocomplete")
            return sorted
        }
    }

    // MARK: - Calendar

    /// Upcoming events whose end is at/after `fromISO` (start-of-today), oldest
    /// first, joined to their calendar for color + name. Mirrors the desktop
    /// useCalendarEvents read.
    func upcomingEvents(fromISO: String, limit: Int = 200) -> [CalendarEvent] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT ce.key, ce.title, ce.start_at, ce.end_at, ce.all_day, ce.location,
                   ce.organizer_name, ce.description, c.color, c.name, ce.account_key, ce.metadata,
                   ce.organizer_email, c.is_writable
            FROM calendar_events ce
            JOIN calendars c ON c.key = ce.calendar_key
            WHERE ce.end_at >= ?1 AND ce.status != '\(CalendarStatusValue.eventCancelled)'
            ORDER BY ce.start_at ASC LIMIT \(max(1, limit))
            """
            let rows = run(sql, binds: [fromISO], mapEvent)
            Log.store.info("loaded \(rows.count) upcoming calendar event(s)")
            return rows
        }
    }

    /// Map an event row — every event query SELECTs the same 14-column projection
    /// (see `upcomingEvents`), so the indices here are the single pairing with it.
    private func mapEvent(_ stmt: OpaquePointer) -> CalendarEvent {
        CalendarEvent(
            id: text(stmt, 0),
            accountKey: text(stmt, 10),
            title: text(stmt, 1).isEmpty ? "(No title)" : text(stmt, 1),
            startAt: text(stmt, 2),
            endAt: text(stmt, 3),
            allDay: sqlite3_column_int(stmt, 4) == 1,
            location: textOrNil(stmt, 5),
            organizerName: textOrNil(stmt, 6),
            organizerEmail: textOrNil(stmt, 12),
            detail: textOrNil(stmt, 7),
            calendarColorHex: textOrNil(stmt, 8),
            calendarName: textOrNil(stmt, 9),
            metadataJSON: textOrNil(stmt, 11),
            calendarWritable: sqlite3_column_int(stmt, 13) != 0
        )
    }

    /// A single event by its local key — used to open a meeting invite straight to
    /// its calendar detail. Same projection as `upcomingEvents`.
    func event(byKey key: String) -> CalendarEvent? {
        queue.sync {
            guard db != nil else { return nil }
            let sql = """
            SELECT ce.key, ce.title, ce.start_at, ce.end_at, ce.all_day, ce.location,
                   ce.organizer_name, ce.description, c.color, c.name, ce.account_key, ce.metadata,
                   ce.organizer_email, c.is_writable
            FROM calendar_events ce
            JOIN calendars c ON c.key = ce.calendar_key
            WHERE ce.key = ?1 LIMIT 1
            """
            return run(sql, binds: [key], mapEvent).first
        }
    }

    /// Events overlapping the half-open window [fromISO, toISO) — used by the month
    /// grid, which (unlike the agenda) needs past days too. Same projection as
    /// `upcomingEvents`.
    func eventsBetween(fromISO: String, toISO: String, limit: Int = 1000) -> [CalendarEvent] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT ce.key, ce.title, ce.start_at, ce.end_at, ce.all_day, ce.location,
                   ce.organizer_name, ce.description, c.color, c.name, ce.account_key, ce.metadata,
                   ce.organizer_email, c.is_writable
            FROM calendar_events ce
            JOIN calendars c ON c.key = ce.calendar_key
            WHERE ce.start_at < ?2 AND ce.end_at >= ?1 AND ce.status != '\(CalendarStatusValue.eventCancelled)'
            ORDER BY ce.start_at ASC LIMIT \(max(1, limit))
            """
            let rows = run(sql, binds: [fromISO, toISO], mapEvent)
            Log.store.info("loaded \(rows.count) calendar event(s) in window")
            return rows
        }
    }

    /// Writable calendars (active, visible) for the New Event picker — the provider
    /// id + account key are what the create FFI needs. IMAP accounts have none.
    /// Calendars a new event can actually be created on. `is_writable` is the
    /// part that matters: a subscribed/holiday/birthday calendar is visible and
    /// has a provider id, but the provider 403s every create — offering it as a
    /// target is how an event ends up nowhere. `is_owned` keeps out calendars
    /// someone else shared with write access, which are a poor place to put
    /// your own meetings. (NULL = a row written before the column existed;
    /// assume both and let the provider decide.)
    func writableCalendars() -> [WritableCalendar] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT account_key, provider_id, name, is_primary
            FROM calendars
            WHERE status = '\(CalendarStatusValue.calendarActive)' AND is_visible = 1 AND provider_id IS NOT NULL
              AND IFNULL(is_writable, 1) = 1 AND IFNULL(is_owned, 1) = 1
            ORDER BY is_primary DESC, name ASC
            """
            return run(sql, binds: []) { stmt in
                WritableCalendar(accountKey: text(stmt, 0), providerId: text(stmt, 1),
                                 name: text(stmt, 2), isPrimary: sqlite3_column_int(stmt, 3) == 1)
            }
        }
    }

    // MARK: - Conversation detail

    /// Messages of a conversation, oldest first — the reader thread. Mirrors
    /// `loadConversationFromDb` (lib/conversationDetail.js).
    func messages(conversationKey: String) -> [Message] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = """
            SELECT key, from_address, to_address, cc_address, subject, body_plain, body_html,
                   is_inbound, is_draft, created_at, sentiment_label, intent_label
            FROM messages WHERE conversation_key = ?1 ORDER BY created_at ASC
            """
            let rows = run(sql, binds: [conversationKey]) { stmt in
                Message(
                    id: text(stmt, 0),
                    fromAddress: text(stmt, 1),
                    toAddress: text(stmt, 2),
                    ccAddress: textOrNil(stmt, 3),
                    subject: text(stmt, 4),
                    bodyPlain: textOrNil(stmt, 5),
                    bodyHTML: textOrNil(stmt, 6),
                    isInbound: sqlite3_column_int(stmt, 7) == 1,
                    isDraft: sqlite3_column_int(stmt, 8) == 1,
                    createdAt: text(stmt, 9),
                    sentimentLabel: textOrNil(stmt, 10),
                    intentLabel: textOrNil(stmt, 11)
                )
            }
            Log.store.info("loaded \(rows.count) messages for \(conversationKey, privacy: .public)")
            return rows
        }
    }

    // MARK: - SQL helpers

    /// `<col> NOT IN ('a','b',…)` from fixed constants (never user input → safe).
    private func statusNotIn(_ statuses: [String], col: String = "status") -> String {
        "\(col) NOT IN (\(statuses.map { "'\($0)'" }.joined(separator: ", ")))"
    }

    /// Prepare, bind positional string params, step, and map each row. All callers
    /// hold `queue`.
    // Not private: InboxStore+Mx.swift (the MX mirror reads) shares the runner.
    func run<T>(_ sql: String, binds: [String], _ map: (OpaquePointer) -> T) -> [T] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.store.error("prepare failed: \(msg, privacy: .public)")
            runError = msg
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, SQLITE_TRANSIENT)
        }
        var out: [T] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(map(stmt!))
            rc = sqlite3_step(stmt)
        }
        // A clean read ends on SQLITE_DONE. Anything else (SQLITE_IOERR, CORRUPT,
        // CANTOPEN, NOTADB, FULL, …) is a real failure mid-read — record it so the
        // caller surfaces a disk-error state instead of silently returning fewer/zero
        // rows that read as an empty mailbox.
        if rc != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.store.error("read failed (rc=\(rc)): \(msg, privacy: .public)")
            runError = msg
        }
        return out
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
    private func textOrNil(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        let s = String(cString: c)
        return s.isEmpty ? nil : s
    }

    private func doubleOrNil(_ stmt: OpaquePointer, _ col: Int32) -> Double? {
        sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, col)
    }
}

/// An on-device auto-rule (local_rules). Conditions/action are stored as JSON;
/// the computed summaries render a human-readable line.
struct LocalRule: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let name: String
    let conditionsJSON: String
    let actionJSON: String
    let enabled: Bool
    let accountKey: String?

    /// "to contains you@… · from is …" from the conditions array.
    var conditionSummary: String {
        guard let data = conditionsJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !arr.isEmpty
        else { return "Any message" }
        return arr.compactMap { c -> String? in
            guard let f = c["field"] as? String else { return nil }
            let op = (c["op"] as? String) ?? "is"
            let v = "\(c["value"] ?? "")"
            return "\(f) \(op) \(v.count > 22 ? String(v.prefix(22)) + "…" : v)"
        }.joined(separator: " · ")
    }

    /// "Run agent (claude-code)" / "Archive" / "Set priority …".
    var actionSummary: String {
        guard let data = actionJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "—" }
        switch obj["type"] as? String {
        case "run_agent":
            let adapter = (obj["adapter_id"] as? String) ?? "agent"
            return "Run agent (\(adapter))"
        case "builtin":
            return "\((obj["builtin"] as? String) ?? "Built-in action")".capitalized
        case "set_quadrant":
            return "Set priority → \((obj["quadrant"] as? String) ?? "")"
        case let other?:
            return other.replacingOccurrences(of: "_", with: " ").capitalized
        default:
            return "Action"
        }
    }

    /// run_agent rules need the desktop CLI harness; built-ins run on iOS.
    var needsDesktop: Bool { actionJSON.contains("\"run_agent\"") }
}

/// An installed CLI agent (local_agents) the rules can dispatch to.
struct LocalAgent: Identifiable, Hashable {
    var id: String { adapterId }
    let displayName: String
    let adapterId: String
    let version: String?
    let enabled: Bool
}

/// A queued outgoing send (`outbox_messages`). The `payload` JSON is the composed
/// `OutgoingMessage`; recipient/subject are parsed lazily for display.
struct OutboxItem: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let accountKey: String
    let payloadJSON: String
    let status: String
    let retryCount: Int
    let maxRetries: Int
    let errorMessage: String?
    let createdAt: String

    private var payload: [String: Any] {
        (payloadJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
    }

    /// First recipient's display name (falls back to the raw to-address).
    var recipient: String {
        let to = payload["to_address"] as? String ?? ""
        let first = MailAddress.parseList(to).first
        return first.map { $0.name.isEmpty ? $0.email : $0.name } ?? "(no recipient)"
    }

    var subject: String {
        let s = (payload["subject"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "(no subject)" : s
    }

    var preview: String {
        let body = (payload["body_plain"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.replacingOccurrences(of: "\n", with: " ")
    }

    var isFailed: Bool { status == OutboxStatusValue.failed }
    var isSending: Bool { status == OutboxStatusValue.sending }

    /// Human status line, e.g. "Failed · 10/10 tries" or "Queued · retry 2/10".
    var statusLine: String {
        switch status {
        case OutboxStatusValue.failed:  return "Failed · \(retryCount)/\(maxRetries) tries"
        case OutboxStatusValue.sending: return "Sending…"
        default:                        return retryCount > 0 ? "Queued · retry \(retryCount)/\(maxRetries)" : "Queued"
        }
    }

    var time: String { RelativeTime.short(createdAt) }
}

/// A calendar that accepts writes (has a provider id) — the target for creating
/// an event. Maps to a `calendars` row.
struct WritableCalendar: Identifiable, Hashable {
    var id: String { providerId }
    let accountKey: String
    let providerId: String
    let name: String
    let isPrimary: Bool
}

/// Inbox filter pills — the single source for these values (no raw strings in the
/// view). inbox2 has no flag concept; the third scope is Triaged (any Eisenhower
/// quadrant assigned).
enum InboxFilter: String, CaseIterable {
    case all = "All"
    case unread = "Unread"
    case triaged = "Triaged"
}

/// A mailbox folder the user can switch to from the hamburger sheet. Inbox /
/// Archive / Trash map to our conversation status; Sent / Drafts are provider
/// folders (joined); the triage cases are the inbox2 quadrant gmail labels.
/// Single source for the title + icon.
enum MailFolder: String, CaseIterable, Identifiable {
    case inbox, sent, drafts, outbox, archive, spam, trash
    case priority, schedule, delegate, later, important
    // Meta channel sub-views (Instagram/Messenger/WhatsApp). Keyed on the
    // conversation `kind` (uniform across channels — a Messenger Page comment and
    // an Instagram comment are both kind=comment). See docs/Cloud-Push.md (Meta).
    case metaAll, metaMessages, metaComments, metaMentions

    var id: String { rawValue }

    /// The standard mailboxes (vs the triage quadrant views).
    static let mailboxes: [MailFolder] = [.inbox, .sent, .drafts, .outbox, .archive, .spam, .trash]
    static let triage: [MailFolder] = [.priority, .schedule, .delegate, .later, .important]
    var isTriage: Bool { Self.triage.contains(self) }

    /// Reader actions that are redundant in this folder (so hidden), mirroring the
    /// web reading pane: Archive is a no-op in Archive/Trash/Sent (a sent thread
    /// already lives in the archive); Trash is a no-op in Trash.
    var hidesArchiveAction: Bool { self == .archive || self == .trash || self == .sent }
    var hidesTrashAction: Bool { self == .trash }

    /// Whether this is a Meta channel sub-view.
    var isMeta: Bool {
        switch self { case .metaAll, .metaMessages, .metaComments, .metaMentions: return true; default: return false }
    }

    /// The conversation `kind` values a Meta sub-view matches; `nil` = no kind
    /// narrow (All). Messages folds in postbacks alongside DMs.
    var metaKinds: [String]? {
        switch self {
        case .metaMessages: return ["dm", "postback"]
        case .metaComments: return ["comment"]
        case .metaMentions: return ["mention"]
        default: return nil   // metaAll (and non-meta) — no kind filter
        }
    }

    /// The Meta sub-views shown for an account's provider type (nil = not Meta →
    /// standard mailboxes). WhatsApp is DM-only, so it shows just Messages.
    static func meta(for provider: String) -> [MailFolder]? {
        switch provider.lowercased() {
        case "whatsapp": return [.metaMessages]
        case "messenger": return [.metaAll, .metaMessages, .metaComments]
        case "instagram": return [.metaAll, .metaMessages, .metaComments, .metaMentions]
        default: return nil
        }
    }

    /// The gmail label name backing a triage view (e.g. "inbox2/Priority"); nil for
    /// standard mailboxes.
    var triageLabel: String? { isTriage ? "inbox2/\(title)" : nil }

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .outbox: return "Outbox"
        case .archive: return "Archive"
        case .spam: return "Spam"
        case .trash: return "Trash"
        case .priority: return "Priority"
        case .schedule: return "Schedule"
        case .delegate: return "Delegate"
        case .later: return "Later"
        case .important: return "Important"
        case .metaAll: return "All"
        case .metaMessages: return "Messages"
        case .metaComments: return "Comments"
        case .metaMentions: return "Mentions"
        }
    }
    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .outbox: return "tray.and.arrow.up"
        case .archive: return "archivebox"
        case .spam: return "exclamationmark.octagon"
        case .trash: return "trash"
        // Triage glyphs match the desktop Eisenhower quadrants (web lib/priority.js).
        case .priority: return "flame.fill"
        case .schedule: return "calendar.badge.clock"
        case .delegate: return "person.badge.plus"
        case .later: return "clock"
        case .important: return "star"
        case .metaAll: return "tray"
        case .metaMessages: return "message"
        case .metaComments: return "text.bubble"
        case .metaMentions: return "at"
        }
    }

    /// Desktop-canonical triage tint — the Eisenhower quadrant colors (+ Important).
    /// nil for the standard mailboxes. Returned as a hex string so the data layer
    /// stays SwiftUI-free; views map it through `Color(hex:)`. Single source of
    /// truth mirrors the web app's `lib/priority.js` QUADRANTS palette.
    var tintHex: String? {
        switch self {
        case .priority: return "e06060"   // DO_FIRST  (urgent + important)
        case .schedule: return "6ea8d9"   // SCHEDULE  (important, not urgent)
        case .delegate: return "d4a843"   // DELEGATE  (urgent, not important)
        case .later: return "6b7280"      // LATER     (neither)
        case .important: return "d0b468"  // star
        default: return nil
        }
    }
}
