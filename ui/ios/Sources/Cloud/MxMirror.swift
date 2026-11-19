import Foundation

/// Drives the engine's local mirror of MX mail (docs/MX-Sync.md) and serves reads
/// from it. The iOS counterpart of `ui/web/src/lib/mxMirror.js` + `localData.js`.
///
/// The Rust engine does the syncing and replays queued actions; this tells it
/// which orgs to mirror and when to run a pass — sign-in, foreground, a push wake
/// (iOS has no realtime socket) — and clears the mirror on sign-out: mail must not
/// outlive the session on the device. `CloudSession` asks here first and falls
/// back to the API whenever the answer is `nil`.
@MainActor
final class MxMirror {
    static let shared = MxMirror()

    private var orgs: Set<String> = []
    private var userKey: String?
    private var running: Set<String> = []
    private static let decoder = JSONDecoder()
    /// One sign-in's worth of passes; the engine's own 60s beat carries on after.
    private static let maxPassesPerKick = 25

    private var engine: InboxEngine? { EngineModel.shared.mxEngine }
    private var store: InboxStore { EngineModel.shared.store }

    // MARK: Driving the engine

    /// The signed-in session changed: hand the engine the bearer (it has none on
    /// iOS otherwise), mirror exactly these orgs as this user, forget the rest.
    func watch(orgIds: [String], userKey: String, token: String?) {
        guard let engine else { return }
        let want = Set(orgIds)
        let switched = self.userKey != userKey
        self.userKey = userKey
        let gone = orgs.subtracting(want)
        let fresh = switched ? want : want.subtracting(orgs)
        orgs = want
        Task.detached {
            engine.setCloudSession(apiBase: AppConfig.apiBase, token: token)
            for org in gone { try? engine.mxForget(org: org) }
            await MainActor.run { fresh.forEach { self.kick($0) } }
        }
    }

    /// Foreground, or a push said something changed: pass for every mirrored org.
    func kickAll(directory: Bool = false) { orgs.forEach { kick($0, directory: directory) } }

    func kick(_ org: String, directory: Bool = false) {
        guard let engine, let userKey, orgs.contains(org), !running.contains(org) else { return }
        running.insert(org)
        Task.detached { [weak self] in
            var directory = directory
            var changed = false
            for _ in 0..<Self.maxPassesPerKick {
                guard let report = try? engine.mxSync(org: org, userKey: userKey, directory: directory, reconcile: directory) else { break }
                directory = false
                changed = changed || report.pulled + report.deleted + report.backfilled + report.hydrated + report.removed > 0
                if !report.more { break }
            }
            let didChange = changed
            await MainActor.run {
                self?.running.remove(org)
                if didChange { CloudSession.shared.mirrorChanged() }
            }
        }
    }

    /// Sealed mail: the identity key opened with the account password, or nil for a
    /// wrong password. Throws when the server can't be reached.
    func unlockIdentity(password: String) async throws -> String? {
        guard let engine else { return nil }
        return try await Task.detached { try engine.mxUnlockIdentity(password: password) }.value
    }

    /// Hand every mirrored org its sealed domain keys. One unreachable org doesn't stop
    /// the others; the caller rechecks the thread it cares about. False if none worked.
    func unlockSealed(identity: String) async -> Bool {
        guard let engine else { return false }
        let targets = orgs
        let ok = await Task.detached {
            targets.map { (try? engine.mxUnlockOrg(org: $0, identityKey: identity)) != nil }.contains(true)
        }.value
        if ok { CloudSession.shared.mirrorChanged() }
        return ok
    }

    /// Sign-out: every mirrored org — mail, queued actions, keys — leaves the device.
    func reset() {
        SealedKeychain.delete()
        let leaving = orgs
        orgs = []; userKey = nil
        guard let engine else { return }
        Task.detached {
            for org in leaving { try? engine.mxForget(org: org) }
            engine.setCloudSession(apiBase: AppConfig.apiBase, token: nil)
        }
    }

    // MARK: Reads (nil → ask the API)

    /// Only what the mirror can evaluate: `direction`, `assignee` and search are the
    /// server's (see the callers), so they never reach here.
    func conversations(orgId: String, status: String?, read: Bool?, domain: String?, page: Int = 1, perPage: Int = 200, labeledOnly: Bool = false) async -> [CloudConversation]? {
        guard let userKey else { return nil }
        let store = self.store
        return await store.read { store in
            guard let org = store.mxOrg(orgId, userKey: userKey) else { return nil }
            let data = store.mxConversations(org: org, status: status, read: read, domain: domain, page: page, perPage: perPage, labeledOnly: labeledOnly)
            return (try? Self.decoder.decode(CloudConversationsResponse.self, from: data))?.conversations
        }
    }

    func conversationDetail(orgId: String, id: String) async -> CloudConversationDetail? {
        guard let userKey else { return nil }
        let store = self.store
        return await store.read { store in
            guard let org = store.mxOrg(orgId, userKey: userKey),
                  let data = store.mxConversationDetail(org: org, id: id) else { return nil }
            return (try? Self.decoder.decode(CloudConversationDetailResponse.self, from: data))?.conversation
        }
    }

    func tags(orgId: String) async -> [CloudTag]? {
        await directory(orgId, "tags") { (r: CloudTagsResponse) in r.tags }
    }

    func members(orgId: String) async -> [CloudMember]? {
        await directory(orgId, "members") { (r: CloudMembersResponse) in r.members }
    }

    private func directory<R: Decodable & Sendable, T: Sendable>(_ orgId: String, _ type: String, _ pick: @escaping @Sendable (R) -> T) async -> T? {
        guard let userKey else { return nil }
        let store = self.store
        return await store.read { store in
            guard let org = store.mxOrg(orgId, userKey: userKey) else { return nil }
            return (try? Self.decoder.decode(R.self, from: store.mxDirectory(org: org, type: type))).map(pick)
        }
    }

    // MARK: Writes

    /// archive / trash / spam / open / mark_read / mark_unread. In the mirror before
    /// this returns, queued durably, sent when the network allows — so it succeeds
    /// offline. `false` = this org isn't mirrored; the caller uses the API.
    func perform(orgId: String, conversationIds: [String], action: String) async -> Bool {
        guard let engine, let userKey else { return false }
        let store = self.store
        guard let org = await store.read({ $0.mxOrg(orgId, userKey: userKey, complete: false) }) else { return false }
        return await Task.detached {
            (try? engine.mxAction(org: org, threads: conversationIds, action: action)) != nil
        }.value
    }
}
