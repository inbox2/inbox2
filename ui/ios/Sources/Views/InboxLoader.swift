import SwiftUI

/// Owns the inbox list's loaded rows and the reads that fill them: the channel/
/// domain/unified fan-out, the Outbox read, the provider-side search pass and the
/// "just removed, don't flicker back" suppression. `InboxListView` drives it with a
/// `Scope` (its current channel/folder/filter/query) and renders what it publishes;
/// `InboxBulkController` mutates `conversations` through it for optimistic removes.
@MainActor
final class InboxLoader: ObservableObject {
    /// What the list is looking at — derived by the view from its own state.
    struct Scope {
        /// nil = unified (all accounts); else the selected account / domain key.
        let accountKey: String?
        let selectedChannel: String
        let isDomainChannel: Bool
        let folder: MailFolder
        /// The pill string (domain view name or `InboxFilter` raw value).
        let filterRaw: String
        let filter: InboxFilter
        let query: String
        /// MX pages (50 rows each) to read per org in the unified list. Lore asks for
        /// more than the inbox's first page: an old open task must not drop off Today.
        var pages: Int = 1
        /// Lore: the local half reads only triage-labelled threads (up to 1000), not
        /// the newest 200 of everything.
        var labeledOnly: Bool = false
        /// The open address folder's key on an MX domain chip (nil = its Inbox).
        var addressFolder: String? = nil
    }

    @Published var conversations: [Conversation] = []
    @Published var outbox: [OutboxItem] = []
    /// Non-nil when the local mailbox read failed (disk I/O, corruption). Drives an
    /// error state in the list instead of the misleading "All clear" empty state.
    @Published var loadError: String?
    /// Conversations the user just removed (archive/trash/spam/snooze) that the
    /// store may still return until the durable write-back commits — suppressed
    /// from re-queries by `applyPendingRemoval` so they don't flicker back in.
    /// Not published: nothing renders from it.
    var pendingRemoved: Set<String> = []
    /// Gmail/Outlook-side search hits for the current query + scope. Cached because
    /// `reload` also runs on every engine data event, and those must not each cost
    /// a provider request.
    private var providerHitCache: (scope: String, keys: [String])?

    /// Suppress rows the user just removed (archive/trash/spam/snooze) from store
    /// re-queries until the write-back commits. The post-action `dataVersion` bump
    /// can re-query SQLite before the durable status write lands, so the store still
    /// returns the row as `open` — which made a just-trashed thread flicker back into
    /// the list for a beat. Once a re-query no longer returns an id, the store has
    /// reconciled and we stop suppressing it (the set self-cleans, never grows here).
    private func applyPendingRemoval(_ rows: [Conversation]) -> [Conversation] {
        guard !pendingRemoved.isEmpty else { return rows }
        let stillPresent = pendingRemoved.intersection(rows.map(\.id))
        if stillPresent != pendingRemoved { pendingRemoved = stillPresent }
        return rows.filter { !pendingRemoved.contains($0.id) }
    }

    /// Read conversations live from the local store for the active channel/filter/
    /// query. Runs off the main thread (so tab switches stay smooth) and assigns the
    /// result back on the main actor. Called on input change + engine data events.
    func reload(_ s: Scope, engine: EngineModel, cloud: CloudSession) async {
        let folder = s.folder, q = s.query
        // Unified (all sources): the default Inbox and search merge the external-channel
        // store with every signed-in org's MX pool into one date-sorted list. Special
        // folders (Outbox/Drafts) stay channel-only in unified — reach a domain's
        // Sent/Drafts via its chip.
        if s.accountKey == nil && (folder == .inbox || !q.isEmpty || s.pages > 1) {
            await reloadUnified(s, engine: engine, cloud: cloud)
            return
        }
        // Domain (API) channel: fetch live from the cloud, mapped to row models.
        // `filterRaw` here is the domain view (All/Mine/Unassigned/Unread).
        if s.isDomainChannel {
            outbox = []; loadError = nil
            let result = await cloud.conversations(folder: folder, view: s.filterRaw, query: q,
                                                   domain: AccountKey.domainFilter(s.selectedChannel),
                                                   addressFolder: s.addressFolder)
            guard !Task.isCancelled else { return }
            conversations = applyPendingRemoval(result)
            return
        }
        let key = s.accountKey, f = s.filter
        if folder == .outbox && q.isEmpty {
            loadError = nil
            let items = await engine.store.read { $0.outboxMessages() }
            guard !Task.isCancelled else { return }
            outbox = items
            conversations = []
        } else {
            let result = await engine.store.read { $0.load(accountKey: key, folder: folder, filter: f, query: q) }
            guard !Task.isCancelled else { return }
            conversations = applyPendingRemoval(result.conversations)
            loadError = result.diskError
            await appendProviderHits(s, engine: engine)
        }
    }

    /// The unified read: fan out the local external-channel store and every signed-in
    /// org's whole-org MX pool (all domains, member-scoped — `domain: nil`) concurrently,
    /// then merge into one list, de-duped by conversation key and sorted by a single
    /// parsed-`updated_at` comparator (newest first) across both sources.
    private func reloadUnified(_ s: Scope, engine: EngineModel, cloud: CloudSession) async {
        outbox = []
        let folder = s.folder, q = s.query, f = s.filter
        // `filterRaw` is one of the unified pills (All/Unread) — valid as both an engine
        // `InboxFilter` (via `filter`) and a cloud view string, so both halves honour
        // the same selection.
        let lore = s.labeledOnly
        async let channelLoad = engine.store.read { $0.load(accountKey: nil, folder: folder, filter: f, query: q, labeledOnly: lore, limit: lore ? 1000 : 200) }
        async let mxLoad = loadOrgPools(folder: folder, view: s.filterRaw, query: q, pages: s.pages, labeledOnly: s.labeledOnly, cloud: cloud)
        let channelResult = await channelLoad
        let mxRows = await mxLoad
        guard !Task.isCancelled else { return }
        var seen = Set<String>()
        let merged = (channelResult.conversations + mxRows)
            .filter { seen.insert($0.id).inserted }
            .sorted { Self.updatedDate($0) > Self.updatedDate($1) }
        conversations = applyPendingRemoval(merged)
        loadError = channelResult.diskError
        await appendProviderHits(s, engine: engine)
    }

    /// Second search pass: Gmail/Outlook search their own index, which reads inside
    /// attachments (local FTS only has filenames), so a word that lives only in an
    /// attached PDF still finds its thread. Local rows are already on screen; the
    /// provider's extra hits are merged in.
    private func appendProviderHits(_ s: Scope, engine: EngineModel) async {
        let q = s.query
        // Exclusions alone (-word) name nothing to look for: the provider would just list recent mail.
        guard !q.isEmpty, await engine.store.read({ $0.hasSearchTerms(q) }) else { return }
        let scope = "\(s.accountKey ?? "*")|\(q)"
        let keys: [String]
        if let cached = providerHitCache, cached.scope == scope {
            keys = cached.keys
        } else {
            keys = await engine.providerSearch(accountKey: s.accountKey, query: q)
            guard !Task.isCancelled else { return }
            providerHitCache = (scope, keys)
        }
        let seen = Set(conversations.map(\.id))
        let missing = keys.filter { !seen.contains($0) }
        guard !missing.isEmpty else { return }
        let f = s.filter
        let rows = await engine.store.read { $0.conversations(keys: missing, filter: f) }
        guard !Task.isCancelled else { return }
        conversations = applyPendingRemoval((conversations + rows).sorted { Self.updatedDate($0) > Self.updatedDate($1) })
    }

    /// Every org's MX pool for the unified list — iterates `cloud.orgs` (not just the
    /// current org) so a multi-org member sees all their team pools; empty when
    /// signed out. Whole-org pool means no domain filter.
    private func loadOrgPools(folder: MailFolder, view: String, query q: String, pages: Int, labeledOnly: Bool, cloud: CloudSession) async -> [Conversation] {
        guard cloud.isSignedIn else { return [] }
        var rows: [Conversation] = []
        for org in cloud.orgs {
            for page in 1...max(1, pages) {
                let batch = await cloud.conversations(folder: folder, view: view, query: q, domain: nil, orgId: org.id, page: page, labeledOnly: labeledOnly)
                rows += batch
                if batch.count < 50 || !q.isEmpty || pages == 1 { break }   // 50-row pages (Lore asks the mirror for 50 too); short = last; search isn't paged
            }
        }
        return rows
    }

    /// Parse a conversation's `updated_at` to a real Date for the merged sort (falls
    /// back to the distant past so unparseable timestamps sink rather than crash).
    private static func updatedDate(_ c: Conversation) -> Date {
        RelativeTime.parse(c.updatedAt) ?? .distantPast
    }
}
