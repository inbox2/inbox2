import Foundation
import SwiftUI

/// Common snooze targets — shared by the inbox-row and reader snooze menus so the
/// "tomorrow / next week" wake times stay identical (9am on the target day).
enum SnoozeDate {
    static func morning(daysFromNow days: Int) -> Date {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
    }
    static var tomorrowMorning: Date { morning(daysFromNow: 1) }
    static var nextWeekMorning: Date { morning(daysFromNow: 7) }
}

/// Auth + identity state for the inbox2-domain ("MX") mode. Holds the session token
/// (in the Keychain), the signed-in user, their orgs, and the active org. On launch
/// it validates the stored token against `GET /account`; an invalid token signs out.
/// This is the counterpart to `EngineModel` (offline channels) for the domain mode.
/// (`OutgoingAttachment` now lives in CloudDTOs.swift, shared with the Share Extension.)

/// A just-sent domain message that can still be undone, until `until`.
struct SentReceipt: Equatable {
    let messageId: String
    let until: Date
}

/// A loaded domain thread + its collaboration state.
struct DomainThread {
    var messages: [Message] = []
    var tags: [CloudTag] = []
    var assignees: [CloudMember] = []
    var notes: [CloudNote] = []
    var sealedLocked = false
    var loaded = false
    /// After an unlock: a thread that failed to load has not been shown to be open.
    var stillLocked: Bool { !loaded || sealedLocked }
}

@MainActor
final class CloudSession: ObservableObject {
    enum State: Equatable { case loading, signedOut, signedIn }

    @Published var state: State = .loading {
        // Every path to signed-out (sign-out, revoked token) takes MX mail off the Unread widget.
        didSet {
            guard state == .signedOut else { return }
            UnreadStack.dropDomain(channelUnread: AppBadge.channelUnread)
            // Every way out (sign-out, expired or revoked token): the saved folder
            // trees belong to the user who was signed in.
            AddressFolderStore.shared.reset()
        }
    }
    @Published var user: CloudUser?
    @Published var orgs: [CloudOrg] = []
    @Published var currentOrgId: String?
    /// The most recent domain send, while it's still cancellable — drives the
    /// inbox's "Undo send" toast. Cleared on undo or when the window lapses.
    @Published var lastSend: SentReceipt?
    /// Set to the `user_id` when login returns a 2FA challenge — the UI then prompts
    /// for a TOTP code and retries.
    @Published var pending2FA: Bool = false
    @Published var lastError: String?
    /// Bumped after any domain mutation that changes the conversation list (read
    /// state, snooze, archive/trash/spam). List views fold this into their reload key
    /// so a change made anywhere — e.g. mark-read from the reader — refreshes them.
    @Published var revision = 0

    var currentOrg: CloudOrg? { orgs.first { $0.id == currentOrgId } ?? orgs.first }
    var isSignedIn: Bool { state == .signedIn }

    /// Keychain account for the MX session token. `nonisolated` + not private: the
    /// image proxy (`ImageProxy.bearer`) reads it off the main actor as the fallback
    /// bearer when no personal API key is set.
    nonisolated static let tokenKey = "session_token"
    private let client = CloudClient()

    /// See EngineModel.shared — same one-per-process rule.
    static let shared = CloudSession()

    init() { Task { await restore() } }

    /// Validate the stored token; sign in if valid, else signed out.
    func restore() async {
        guard let token = Keychain.get(Self.tokenKey) else { state = .signedOut; return }
        await client.setToken(token)
        do {
            apply(try await client.account())
            state = .signedIn
            await refreshUnreadCount()
            Log.cloud.info("restored session for \(self.user?.username ?? "?")")
        } catch {
            Log.cloud.info("stored token invalid; signing out")
            Keychain.delete(Self.tokenKey)
            state = .signedOut
        }
    }

    /// Attempt a login. Returns true on success; sets `pending2FA` (and returns false)
    /// when the server asks for a TOTP code — call again with `totp` filled in.
    func login(username: String, password: String, totp: String? = nil) async -> Bool {
        lastError = nil
        do {
            let resp = try await client.login(username: username, password: password, totp: totp)
            if resp.requiresTwoFactor == true {
                pending2FA = true
                Log.cloud.info("login needs 2FA for \(username)")
                return false
            }
            guard let token = resp.token else { lastError = "No token returned."; return false }
            Keychain.set(token, for: Self.tokenKey)
            await client.setToken(token)
            apply(try await client.account())
            pending2FA = false
            state = .signedIn
            await refreshUnreadCount()
            Log.cloud.info("signed in \(username)")
            return true
        } catch {
            lastError = (error as? CloudError)?.errorDescription ?? error.localizedDescription
            Log.cloud.error("login failed: \(self.lastError ?? "", privacy: .public)")
            return false
        }
    }

    /// Adopt a freshly-minted device-link token (an `ink_` account bearer) exactly as
    /// if the user had just logged in: store it in the Keychain, validate it against
    /// `GET /account` (which accepts an `ink_` key as a bearer), and populate identity.
    /// On a bad/expired token the Keychain entry is cleared and the error rethrown so
    /// the caller can surface it. Triggers push registration the same way login does —
    /// `PushRegistrar.registerWithAPI` falls back to `CloudSession.tokenKey` for its
    /// bearer, so once the token is stored it can complete a deferred registration.
    // MARK: Open tracking (per-channel config sync, docs/Open-Tracking.md)

    func channelTracking() async -> [CloudChannelTracking] {
        (try? await client.channelTracking()) ?? []
    }

    func saveChannelTracking(email: String, enabled: Bool, trackDomain: String?) async {
        do { try await client.setChannelTracking(email: email, enabled: enabled, trackDomain: trackDomain) }
        catch { Log.cloud.warning("saveChannelTracking failed: \(String(describing: error), privacy: .public)") }
    }

    func adoptLinkedToken(_ token: String) async throws {
        lastError = nil
        Keychain.set(token, for: Self.tokenKey)
        await client.setToken(token)
        do {
            apply(try await client.account())
        } catch {
            Keychain.delete(Self.tokenKey)
            await client.setToken(nil)
            state = .signedOut
            lastError = (error as? CloudError)?.errorDescription ?? error.localizedDescription
            Log.cloud.error("device-link adoption failed: \(self.lastError ?? "", privacy: .public)")
            throw error
        }
        pending2FA = false
        state = .signedIn
        await refreshUnreadCount()
        // Complete any push registration that was deferred while signed out (no-op if
        // already registered) — mirrors the foreground `ensureRegistered` retry.
        await PushRegistrar.ensureRegistered()
        Log.cloud.info("adopted linked device token for \(self.user?.username ?? "?")")
    }

    func signOut() async {
        MxMirror.shared.reset() // the mirrored mail leaves the device with the session
        await client.logout()
        Keychain.delete(Self.tokenKey)
        await client.setToken(nil)
        user = nil; orgs = []; currentOrgId = nil; pending2FA = false; lastError = nil
        state = .signedOut
        AppBadge.clearDomain()
        AddressFolderStore.shared.reset()
        Log.cloud.info("signed out")
    }

    func selectOrg(_ id: String) { currentOrgId = id }

    /// Re-pull /account while signed in so a domain added/removed elsewhere (console,
    /// another device) surfaces — mobile has no realtime channel, so this runs on
    /// foreground. Unlike `apply`, it keeps the current org selection if it still
    /// exists. Only a 401 signs out (via `handleAuthError`); a transient/offline
    /// failure leaves the session and org list intact.
    func refreshAccount() async {
        guard isSignedIn else { return }
        do {
            let acct = try await client.account()
            user = acct.account
            orgs = acct.organizations
            if currentOrgId == nil || !acct.organizations.contains(where: { $0.id == currentOrgId }) {
                currentOrgId = acct.currentOrgId ?? acct.organizations.first?.id
            }
            // Runs on every foreground: mobile has no realtime socket, so this is
            // when the mirror catches up (plus push wakes and the engine's own beat).
            mirror()
            MxMirror.shared.kickAll()
            AddressFolderStore.shared.refreshAll()
        } catch { await handleAuthError(error) }
    }

    /// Keep the engine's local mirror of MX mail pointed at this session's orgs
    /// (docs/MX-Sync.md). Idempotent.
    private func mirror() {
        guard let user else { return }
        MxMirror.shared.watch(orgIds: orgs.map(\.id), userKey: user.id, token: Keychain.get(Self.tokenKey))
    }

    /// The mirror moved (a pass brought changes): refresh what's on screen.
    func mirrorChanged() { markChanged(); AddressFolderStore.shared.refreshAll() }

    private func apply(_ acct: CloudAccountResponse) {
        user = acct.account
        orgs = acct.organizations
        currentOrgId = acct.currentOrgId ?? acct.organizations.first?.id
        mirror()
    }

    /// Jev triage metadata (docs/Triage.md): every org's label names, for MX rows'
    /// custom-label chips, and the current org's classifiable Spaces, pushed to the
    /// engine as `set_space_taxonomy` objects so local-channel triage files into them
    /// too. Best-effort — a failed fetch leaves the last values in place.
    func syncTriageMeta() async {
        guard isSignedIn else { return }
        for org in orgs {
            if let r: TriageLabelsResponse = try? await client.request("GET", "/orgs/\(org.id)/triage-labels", authed: true) {
                TriageLabelNames.byOrg[org.id] = Dictionary(r.triageLabels.map { ($0.slug, $0.name) },
                                                            uniquingKeysWith: { a, _ in a })
            }
        }
        guard let orgId = currentOrgId,
              let r: SpacesResponse = try? await client.request("GET", "/orgs/\(orgId)/spaces", authed: true)
        else { return }
        let taxonomy: [[String: String]] = r.spaces.compactMap { s in
            guard s.classify != false, let slug = s.slug, !slug.isEmpty else { return nil }
            return ["slug": slug, "name": s.name ?? slug, "description": s.description ?? "", "not_for": s.notFor ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: taxonomy) else { return }
        EngineModel.shared.setSpaceTaxonomy(String(decoding: data, as: UTF8.self))
        Log.cloud.info("pushed \(taxonomy.count) classifiable spaces to the engine")
    }

    private struct TriageLabelsResponse: Decodable {
        let triageLabels: [TriageLabelDef]
        enum CodingKeys: String, CodingKey { case triageLabels = "triage_labels" }
    }

    private struct SpacesResponse: Decodable {
        struct Space: Decodable {
            let slug: String?
            let name: String?
            let description: String?
            let notFor: String?
            let classify: Bool?
            enum CodingKeys: String, CodingKey {
                case slug, name, description, classify
                case notFor = "not_for"
            }
        }
        let spaces: [Space]
    }

    /// Recompute the domain (MX) half of the app-icon badge. Best-effort: on
    /// failure (offline / auth) the last value stands rather than zeroing.
    func refreshUnreadCount() async {
        guard isSignedIn, let orgId = currentOrgId else { return }
        do { AppBadge.setDomainUnread(try await client.unreadCount(orgId: orgId)) }
        catch { Log.cloud.info("domain unread refresh failed: \(String(describing: error), privacy: .public)") }
    }

    /// One org's inbox unread count (the Unread widget totals every org); nil on failure.
    func unreadCount(orgId: String) async -> Int? {
        guard isSignedIn else { return nil }
        return try? await client.unreadCount(orgId: orgId)
    }

    /// One domain's address-folder tree; nil when it can't be read (offline, 404).
    func addressFolders(orgId: String, domain: String) async -> [AddressFolder]? {
        do { return try await client.addressFolders(orgId: orgId, domain: domain) }
        catch { await handleAuthError(error); return nil }
    }

    func setAddressFolderPref(orgId: String, address: String, inbox: Bool?, notify: Bool?) async {
        do { try await client.setAddressFolderPref(orgId: orgId, address: address, inbox: inbox, notify: notify) }
        catch {
            Log.cloud.info("folder pref save failed: \(String(describing: error), privacy: .public)")
            await handleAuthError(error)
        }
    }

    /// Bump the list-refresh signal and re-sync the badge after a domain mutation.
    private func markChanged() {
        Task { await MailActivityManager.shared.refresh() }
        revision += 1
        Task { await refreshUnreadCount() }
        AddressFolderStore.shared.reloadActive()   // the folder unread counts moved too
    }

    // MARK: - Domain mail (mapped into the shared row/reader models)

    /// Map an inbox folder to the API `status` param (nil = the open pool). Sent /
    /// Drafts are view-based on the server and handled separately later.
    private func status(for folder: MailFolder) -> String? {
        switch folder {
        case .archive: return ConvStatusValue.archived
        case .trash: return ConvStatusValue.trash
        default: return nil
        }
    }

    /// Translate a conversation action to the API bulk action. Returns nil for the
    /// actions the domain pool doesn't support (flag/quadrant — it uses tags/assignment).
    func domainAction(for action: ConversationAction) -> String? {
        switch action {
        case .archive, .trash, .spam, .markRead, .markUnread, .loreDone, .loreUndone: return action.verb
        case .unarchive, .untrash, .unspam: return "open"
        case .flag, .unflag, .setQuadrant, .clearQuadrant: return nil
        }
    }

    /// Domain views shown as filter pills (the team-pool navigation model).
    static let views = ["All", "Mine", "Unassigned", "Unread"]

    /// `domain` (a `dom_…` key) narrows the org pool to one workspace domain; nil
    /// lists the whole org (the legacy single-domain chip). `orgId` defaults to the
    /// current org; the unified inbox passes each org explicitly to pool every org
    /// the user belongs to.
    /// `labeledOnly` (Lore): only triage-labelled threads, filtered before paging.
    /// `addressFolder` (a folder key) lists that address folder instead of the Inbox.
    func conversations(folder: MailFolder, view: String, query: String, domain: String? = nil, orgId: String? = nil, page: Int = 1,
                       labeledOnly: Bool = false, addressFolder: String? = nil) async -> [Conversation] {
        guard let orgId = orgId ?? currentOrgId else { return [] }
        do {
            // Drafts are messages, not conversations — list them from the drafts endpoint.
            if folder == .drafts, query.isEmpty {
                let drafts = try await client.drafts(orgId: orgId)
                return drafts.compactMap { Conversation(draft: $0, orgId: orgId) }
            }
            let read: Bool? = view == "Unread" ? false : nil
            let assignee: String? = view == "Mine" ? "me" : (view == "Unassigned" ? "none" : nil)
            let direction = folder == .sent ? "outbound" : nil
            // Inbox is mail for you; the rest of the domain sits in address folders.
            // Search and Lore span the whole pool, like the web's Space drill-down.
            let byFolder = folder == .inbox && query.isEmpty && !labeledOnly
            let folderKey = byFolder ? (addressFolder ?? AddressFolder.inboxKey) : nil
            if byFolder, addressFolder == nil { await AddressFolderStore.shared.ensureLoaded(orgId: orgId) }
            let localFolder: MxFolderFilter? = byFolder ? (addressFolder.map { .address($0) } ?? AddressFolderStore.shared.inboxFilter) : nil
            // The local mirror answers what it can evaluate — instantly, and offline.
            // Search, Sent (direction) and the assignee views are the server's.
            if query.isEmpty, direction == nil, assignee == nil,
               let local = await MxMirror.shared.conversations(orgId: orgId, status: status(for: folder), read: read, domain: domain, folder: localFolder,
                                                                    page: page, perPage: labeledOnly ? 50 : 200, labeledOnly: labeledOnly) {
                #if DEBUG
                if byFolder {
                    InboxFilterLog.note("list|\(orgId)|\(domain ?? "*")|\(view)",
                        "list org=\(orgId) domain=\(domain ?? "all") view=\(view) path=mirror rows=\(local.count) \(InboxFilterLog.describe(localFolder)) mirror=\(await MxMirror.shared.breakdown(orgId: orgId))")
                }
                #endif
                return local.map { Conversation(cloud: $0, orgId: orgId) }
            }
            let rows = try await client.conversations(orgId: orgId, status: status(for: folder),
                                                      read: read, direction: direction, assignee: assignee,
                                                      search: query.isEmpty ? nil : query, domain: domain, folder: folderKey, page: page,
                                                      labeled: labeledOnly)
            #if DEBUG
            if byFolder {
                InboxFilterLog.note("list|\(orgId)|\(domain ?? "*")|\(view)",
                    "list org=\(orgId) domain=\(domain ?? "all") view=\(view) path=rest folder=\(folderKey.map(InboxFilterLog.redact) ?? "-") rows=\(rows.count)")
            }
            #endif
            return rows.map { Conversation(cloud: $0, orgId: orgId) }
        } catch { await handleAuthError(error); return [] }
    }

    /// Load a domain thread: messages (mapped) + collaboration state (tags,
    /// assignees, notes — the read path the API now exposes).
    func thread(conversationId: String, orgId: String? = nil) async -> DomainThread {
        guard let orgId = orgId ?? currentOrgId else { return DomainThread() }
        do {
            let mirrored = await MxMirror.shared.conversationDetail(orgId: orgId, id: conversationId)
            let d = if let mirrored { mirrored } else { try await client.conversationDetail(orgId: orgId, id: conversationId) }
            return DomainThread(messages: d.messages.map { Message(cloud: $0) },
                                tags: d.tags ?? [], assignees: d.assignees ?? [], notes: d.notes ?? [],
                                sealedLocked: d.messages.contains(where: \.isLocked), loaded: true)
        } catch { await handleAuthError(error); return DomainThread() }
    }

    /// The org's full tag palette (for the tag editor).
    func orgTags(orgId: String? = nil) async -> [CloudTag] {
        guard let orgId = orgId ?? currentOrgId else { return [] }
        if let local = await MxMirror.shared.tags(orgId: orgId) { return local }
        do { return try await client.tags(orgId: orgId) }
        catch { await handleAuthError(error); return [] }
    }

    /// Make a private label for the signed-in member. nil on failure (a taken
    /// name, or one of the priority names).
    func createPrivateLabel(name: String, orgId: String? = nil) async -> CloudTag? {
        guard let orgId = orgId ?? currentOrgId else { return nil }
        do { return try await client.createPrivateLabel(orgId: orgId, name: name) }
        catch { await handleAuthError(error); return nil }
    }

    /// Replace a conversation's tags. Returns success.
    func setTags(conversationId: String, tagIds: [String], orgId: String? = nil) async -> Bool {
        guard let orgId = orgId ?? currentOrgId else { return false }
        do { try await client.setTags(orgId: orgId, conversationId: conversationId, tagIds: tagIds); return true }
        catch { await handleAuthError(error); return false }
    }

    /// The org's active members (for the assignee picker).
    func orgMembers(orgId: String? = nil) async -> [CloudMember] {
        guard let orgId = orgId ?? currentOrgId else { return [] }
        if let local = await MxMirror.shared.members(orgId: orgId) { return local }
        do { return try await client.members(orgId: orgId) }
        catch { await handleAuthError(error); return [] }
    }

    /// Replace a conversation's assignees; returns the new list (nil on failure).
    func setAssignees(conversationId: String, memberIds: [String], orgId: String? = nil) async -> [CloudMember]? {
        guard let orgId = orgId ?? currentOrgId else { return nil }
        do { return try await client.setAssignees(orgId: orgId, conversationId: conversationId, memberIds: memberIds) }
        catch { await handleAuthError(error); return nil }
    }

    /// RSVP to a domain meeting invite. `orgId` is the thread's account key (org id,
    /// which is how domain messages route). Returns success.
    func rsvp(orgId: String, messageId: String, status: String) async -> Bool {
        do { try await client.rsvp(orgId: orgId, messageId: messageId, status: status); return true }
        catch { await handleAuthError(error); return false }
    }

    /// Accept/decline a meet-link booking request. nil on success, else the reason.
    func answerMeetingRequest(orgId: String, requestId: String, accept: Bool, reason: String?) async -> String? {
        do { try await client.answerMeetingRequest(orgId: orgId, requestId: requestId, accept: accept, reason: reason); return nil }
        catch { await handleAuthError(error); return error.localizedDescription }
    }

    /// MX counterpart of the engine's `addInviteToCalendar`: file an emailed event on
    /// the member's calendar. Returns success.
    func importCalendarEvent(orgId: String, messageId: String) async -> Bool {
        do { try await client.importCalendarEvent(orgId: orgId, messageId: messageId); return true }
        catch { await handleAuthError(error); return false }
    }

    /// Add an internal note; returns the created note (nil on failure).
    func addNote(conversationId: String, body: String, orgId: String? = nil) async -> CloudNote? {
        guard let orgId = orgId ?? currentOrgId else { return nil }
        do { return try await client.addNote(orgId: orgId, conversationId: conversationId, body: body) }
        catch { await handleAuthError(error); return nil }
    }

    /// Apply a bulk action (already translated via `domainAction`). Returns success.
    /// `orgId` overrides the current org — a notification action carries the org the
    /// push came from, which need not be the one selected in the UI.
    func perform(conversationIds: [String], action: String, orgId: String? = nil) async -> Bool {
        guard let orgId = orgId ?? currentOrgId else { return false }
        do {
            // Mirrored org: the engine applies it locally, queues it and sends it —
            // so it works offline. Otherwise straight to the API.
            if !(await MxMirror.shared.perform(orgId: orgId, conversationIds: conversationIds, action: action)) {
                try await client.bulk(orgId: orgId, conversationIds: conversationIds, action: action)
            }
            markChanged()
            if NotificationManager.bannerClearingVerbs.contains(action) {
                NotificationManager.shared.removeDelivered(conversationKeys: conversationIds)
            }
            return true
        }
        catch { await handleAuthError(error); return false }
    }

    private static let snoozeFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Snooze a conversation until `date`. Returns success.
    func snooze(conversationId: String, until date: Date, orgId: String? = nil) async -> Bool {
        guard let orgId = orgId ?? currentOrgId else { return false }
        do { try await client.snooze(orgId: orgId, conversationId: conversationId, untilISO: Self.snoozeFmt.string(from: date)); markChanged(); return true }
        catch { await handleAuthError(error); return false }
    }

    func markRead(conversationId: String, read: Bool, orgId: String? = nil) async {
        guard let orgId = orgId ?? currentOrgId else { return }
        do {
            if !(await MxMirror.shared.perform(orgId: orgId, conversationIds: [conversationId], action: read ? "mark_read" : "mark_unread")) {
                try await client.updateConversation(orgId: orgId, id: conversationId, read: read)
            }
            markChanged()
            if read { NotificationManager.shared.removeDelivered(conversationKeys: [conversationId]) }
        }
        catch { await handleAuthError(error) }
    }

    func send(conversationId: String?, from: String, to: String, cc: String?, subject: String?,
              bodyPlain typed: String, attachments: [OutgoingAttachment] = [], orgId: String? = nil,
              signature: MailSignature? = nil) async -> Bool {
        // A fresh compose can pick any org's identity from the From menu, so the send
        // must go to THAT org — not whichever one the inbox happens to be showing.
        guard let orgId = orgId ?? currentOrgId else { return false }
        let (bodyPlain, bodyHtml) = MailSignature.body(plain: typed, signature: signature)
        do {
            let messageId: String
            if attachments.isEmpty {
                messageId = try await client.send(orgId: orgId, conversationId: conversationId, from: from, to: to,
                                                  cc: cc, subject: subject, bodyPlain: bodyPlain, bodyHtml: bodyHtml)
            } else {
                // Attachments need a message to upload against: create a draft, upload
                // to it, send threaded to the draft's conversation, then drop the draft.
                let draft = try await client.createDraft(orgId: orgId, from: from, to: to, cc: cc,
                                                         subject: subject, bodyPlain: bodyPlain, bodyHtml: bodyHtml,
                                                         conversationId: conversationId)
                var keys: [String] = []
                for a in attachments {
                    keys.append(try await client.uploadAttachment(orgId: orgId, messageId: draft.id,
                                                                  filename: a.filename, mimeType: a.mimeType, data: a.data))
                }
                messageId = try await client.send(orgId: orgId, conversationId: conversationId ?? draft.conversationId,
                                                  from: from, to: to, cc: cc, subject: subject, bodyPlain: bodyPlain,
                                                  bodyHtml: bodyHtml, attachmentKeys: keys)
                await client.deleteDraft(orgId: orgId, draftId: draft.id)
            }
            armUndo(messageId: messageId)
            return true
        } catch { await handleAuthError(error); return false }
    }

    /// Schedule a domain message for later: create a draft (with any attachments),
    /// then schedule it for `date`. Returns success.
    func scheduleSend(conversationId: String?, from: String, to: String, cc: String?, subject: String?,
                      bodyPlain typed: String, attachments: [OutgoingAttachment] = [], at date: Date,
                      orgId: String? = nil, signature: MailSignature? = nil) async -> Bool {
        guard let orgId = orgId ?? currentOrgId else { return false }
        let (bodyPlain, bodyHtml) = MailSignature.body(plain: typed, signature: signature)
        do {
            let draft = try await client.createDraft(orgId: orgId, from: from, to: to, cc: cc,
                                                     subject: subject, bodyPlain: bodyPlain, bodyHtml: bodyHtml,
                                                     conversationId: conversationId)
            for a in attachments {
                _ = try await client.uploadAttachment(orgId: orgId, messageId: draft.id,
                                                      filename: a.filename, mimeType: a.mimeType, data: a.data)
            }
            try await client.scheduleSend(orgId: orgId, draftId: draft.id, sendAtISO: Self.snoozeFmt.string(from: date))
            return true
        } catch { await handleAuthError(error); return false }
    }

    /// Signatures per org, refetched when older than five minutes (a change in
    /// Settings on another device shows up on the next compose).
    private var signatureCache: [String: (at: Date, applied: [String: MailSignature])] = [:]

    /// The signature for mail from `address` in `orgId`, or nil.
    func signature(orgId: String, from address: String) async -> MailSignature? {
        if let c = signatureCache[orgId], c.at.timeIntervalSinceNow > -300 { return c.applied[address.lowercased()] }
        guard let applied = try? await client.signatures(orgId: orgId) else { return signatureCache[orgId]?.applied[address.lowercased()] }
        signatureCache[orgId] = (Date(), applied)
        return applied[address.lowercased()]
    }

    /// Surface the "Undo send" affordance for the undo window, then auto-clear.
    private func armUndo(messageId: String) {
        let receipt = SentReceipt(messageId: messageId, until: Date().addingTimeInterval(10))
        lastSend = receipt
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if lastSend == receipt { lastSend = nil }
        }
    }

    /// Undo the last domain send (reverts it to a draft server-side).
    func undoLastSend() async {
        guard let orgId = currentOrgId, let r = lastSend else { return }
        lastSend = nil
        do { try await client.cancelSend(orgId: orgId, messageId: r.messageId) }
        catch { await handleAuthError(error) }
    }

    /// On a 401, clear the token and drop to signed-out so the UI prompts re-login.
    private func handleAuthError(_ error: Error) async {
        guard let ce = error as? CloudError, ce.isUnauthorized else { return }
        Keychain.delete(Self.tokenKey)
        await client.setToken(nil)
        user = nil; orgs = []; currentOrgId = nil
        state = .signedOut
        Log.cloud.info("401 — session expired, signed out")
    }

    /// The token-carrying client, shared with the domain-mail layer.
    func mailClient() -> CloudClient { client }
}

// MARK: - Lore (docs/plans/lore.md): mined facts per MX org + the person's C:\Lore pages

extension CloudSession {
    /// Facts the server-side miner learned about one entity, from every org.
    func loreFacts(kind: String, domain: String?, address: String?) async -> [LoreFact] {
        guard let q = kind == "organization" ? domain : address else { return [] }
        let client = mailClient()
        var out: [LoreFact] = []
        for org in orgs {
            do {
                let rows = try await client.loreEntities(orgId: org.id, kind: kind, q: q)
                guard let hit = rows.first(where: { kind == "organization" ? $0.emailDomain == domain : $0.address == address }) else { continue }
                out += try await client.loreEntityFacts(orgId: org.id, id: hit.id)
            } catch {
                Log.cloud.error("lore facts \(org.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return out
    }

    /// The pages in C:\Lore (C:\ is the same disk from every team, so the first org
    /// whose Disk answers reaches it). Read-only here: no folder or page is created.
    func lorePages() async -> (orgId: String, pages: [LorePageRef])? {
        let client = mailClient()
        for org in orgs {
            guard let root = try? await client.diskRoot(orgId: org.id) else { continue }
            do {
                guard let folder = try await client.diskChildren(orgId: org.id, parentId: root)
                    .first(where: { $0.name == "Lore" && ($0.kind ?? "folder") == "folder" }) else { return (org.id, []) }
                // Sealed nodes have no readable name: skip them (Lore pages are never sealed).
                let pages = try await client.diskChildren(orgId: org.id, parentId: folder.id, type: "pages")
                    .compactMap { n in n.kind == "page" ? n.name.map { LorePageRef(id: n.id, name: $0, kind: n.kind) } : nil }
                return (org.id, pages)
            } catch {
                // Another org reaches the same C:\ — try it before giving up.
                Log.cloud.error("lore pages via \(org.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    func lorePageMarkdown(orgId: String, id: String) async throws -> String {
        try await mailClient().diskPageMarkdown(orgId: orgId, id: id)
    }
}
