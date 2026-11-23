import Foundation

/// Errors from the inbox2-domain (MX) API.
enum CloudError: Error, LocalizedError {
    case notAuthenticated
    case http(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not signed in."
        case .http(let code, let msg):
            if code == 401 { return "You've been signed out. Sign in again." }
            return msg.isEmpty ? "Request failed (\(code))." : msg
        case .decoding(let m): return "Couldn't read the server response. \(m)"
        case .transport(let m): return m
        }
    }
    var isUnauthorized: Bool { if case .http(401, _) = self { return true }; return false }
}

/// REST client for the inbox2 domain (MX) API — Bearer-token auth over `/api/v1`.
/// Unlike the offline channels (local SQLite), domain mail is always fetched live
/// from here. The client is an actor so the token is mutated safely across tasks.
actor CloudClient {
    /// Resolved by `AppConfig`: localhost on the simulator, the Mac's Tailscale name
    /// on a physical device, overridable via the `inbox2_cloud_api_base` UserDefault.
    static var baseURL: String { AppConfig.apiBase }

    private var token: String?
    func setToken(_ t: String?) { token = t }

    // MARK: - Auth

    func login(username: String, password: String, totp: String?) async throws -> CloudLoginResponse {
        var body: [String: Any] = ["username": username, "password": password]
        if let totp, !totp.isEmpty { body["totp_code"] = totp }
        return try await request("POST", "/auth/login", body: body, authed: false)
    }

    func account() async throws -> CloudAccountResponse {
        try await request("GET", "/account", authed: true)
    }

    // MARK: - Open tracking (per-channel config sync, docs/Open-Tracking.md)

    func channelTracking() async throws -> [CloudChannelTracking] {
        let resp: CloudChannelTrackingList = try await request("GET", "/tracking/channels", authed: true)
        return resp.channels
    }

    func setChannelTracking(email: String, enabled: Bool, trackDomain: String?) async throws {
        let body: [String: Any] = ["email": email, "open_tracking_enabled": enabled, "track_domain": trackDomain ?? ""]
        try await requestVoid("PUT", "/tracking/channels", body: body, authed: true)
    }

    func logout() async {
        _ = try? await requestVoid("POST", "/auth/logout", authed: true)
    }

    // MARK: - Mail (read)

    /// List the org pool. `status` filters lifecycle (open/archived/trash/spam);
    /// `direction:"outbound"` is the Sent folder; `search` runs the server FTS.
    func conversations(orgId: String, status: String?, read: Bool?, direction: String? = nil, assignee: String? = nil, search: String?, domain: String? = nil, folder: String? = nil, page: Int = 1, labeled: Bool = false) async throws -> [CloudConversation] {
        if let search, !search.isEmpty {
            let q = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
            let resp: CloudConversationsResponse = try await request("GET", "/orgs/\(orgId)/search?q=\(q)", authed: true)
            return resp.conversations
        }
        var path = "/orgs/\(orgId)/conversations?page=\(page)&per_page=50"
        if let status { path += "&status=\(status)" }
        if let read { path += "&read=\(read)" }
        if let direction { path += "&direction=\(direction)" }
        if let assignee { path += "&assignee=\(assignee)" }
        if let domain { path += "&domain=\(domain)" }
        if let folder { path += "&folder=\(Self.query(folder))" }
        if labeled { path += "&labeled=true" }   // any label but resolved, custom ones included
        let resp: CloudConversationsResponse = try await request("GET", path, authed: true)
        return resp.conversations
    }

    /// Unread count for the org's Inbox (mail for you, across your domains) — the
    /// domain/MX half of the app badge.
    func unreadCount(orgId: String) async throws -> Int {
        let resp: CloudUnreadCountResponse = try await request("GET", "/orgs/\(orgId)/conversations/unread-count?folder=inbox", authed: true)
        return resp.unreadCount
    }

    // MARK: Address folders

    /// The domain's folder tree, in display order.
    func addressFolders(orgId: String, domain: String) async throws -> [AddressFolder] {
        let resp: AddressFoldersResponse = try await request("GET", "/orgs/\(orgId)/folders?domain=\(Self.query(domain))", authed: true)
        return resp.folders
    }

    /// Show in Inbox / the bell for one folder (`address` = full address or "inbox").
    func setAddressFolderPref(orgId: String, address: String, inbox: Bool?, notify: Bool?) async throws {
        var body: [String: Any] = ["address": address]
        if let inbox { body["inbox"] = inbox }
        if let notify { body["notify"] = notify }
        try await requestVoid("PATCH", "/orgs/\(orgId)/folders/prefs", body: body, authed: true)
    }

    /// A query value: `+` escaped too (a form decoder reads it as a space), so "vince+receipts" survives.
    private static func query(_ v: String) -> String {
        (v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? v)
    }

    /// Draft messages (the Drafts folder). Each now carries its `conversation_id`.
    func drafts(orgId: String) async throws -> [CloudMessage] {
        let resp: CloudDraftsResponse = try await request("GET", "/orgs/\(orgId)/drafts", authed: true)
        return resp.drafts
    }

    // MARK: Lore (docs/Ontology.md) + Disk pages (docs/plans/disk.md)

    func loreEntities(orgId: String, kind: String, q: String) async throws -> [LoreEntityRow] {
        // URLComponents escapes the value; `+` too, which a form decoder reads as a space.
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "kind", value: kind), URLQueryItem(name: "q", value: q)]
        let query = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        let resp: LoreEntitiesResponse = try await request("GET", "/orgs/\(orgId)/lore/entities?\(query)", authed: true)
        return resp.entities
    }

    func loreEntityFacts(orgId: String, id: String) async throws -> [LoreFact] {
        let resp: LoreEntityResponse = try await request("GET", "/orgs/\(orgId)/lore/entities/\(id)", authed: true)
        return resp.entity.facts ?? []
    }

    /// Only the domain name leaves the device — never mail.
    func brand(domain: String) async throws -> CloudBrand? {
        let d = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? domain
        let resp: CloudBrandResponse = try await request("GET", "/brands/\(d)", authed: true)
        return resp.brand
    }

    struct DiskNode: Decodable { let id: String; let name: String?; let kind: String? }   // name is null on a sealed node
    private struct DiskDrives: Decodable {
        struct Settings: Decodable { let state: String? }
        let cDrive: DiskNode
        let settings: Settings?
        enum CodingKeys: String, CodingKey { case settings; case cDrive = "c_drive" }
    }
    private struct DiskChildren: Decodable {
        let nodes: [DiskNode]?
        let nextCursor: String?
        enum CodingKeys: String, CodingKey { case nodes; case nextCursor = "next_cursor" }
    }
    private struct DiskPage: Decodable { struct Page: Decodable { let markdown: String? }; let page: Page }

    /// C:\ (the person's own disk) root id; nil when this team's Disk is off.
    func diskRoot(orgId: String) async throws -> String? {
        let d: DiskDrives = try await request("GET", "/orgs/\(orgId)/disk", authed: true)
        // A downgraded team's Disk is read_only: reads still work, and the phone only reads.
        return ["active", "read_only"].contains(d.settings?.state ?? "active") ? d.cDrive.id : nil
    }

    /// Every child of a folder (the listing is cursor-paged).
    func diskChildren(orgId: String, parentId: String, type: String? = nil) async throws -> [DiskNode] {
        var out: [DiskNode] = [], cursor: String? = nil
        repeat {
            var path = "/orgs/\(orgId)/disk/nodes/\(parentId)/children?sort=name&dir=asc"
            if let type { path += "&type=\(type)" }
            if let cursor { path += "&cursor=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)" }
            let page: DiskChildren = try await request("GET", path, authed: true)
            out += page.nodes ?? []
            cursor = page.nextCursor
        } while cursor != nil
        return out
    }

    func diskPageMarkdown(orgId: String, id: String) async throws -> String {
        let p: DiskPage = try await request("GET", "/orgs/\(orgId)/disk/pages/\(id)", authed: true)
        return p.page.markdown ?? ""
    }

    func conversationDetail(orgId: String, id: String) async throws -> CloudConversationDetail {
        let resp: CloudConversationDetailResponse = try await request("GET", "/orgs/\(orgId)/conversations/\(id)", authed: true)
        return resp.conversation
    }

    func views(orgId: String) async throws -> [CloudView] {
        let resp: CloudViewsResponse = try await request("GET", "/orgs/\(orgId)/views", authed: true)
        return resp.views
    }

    func tags(orgId: String) async throws -> [CloudTag] {
        let resp: CloudTagsResponse = try await request("GET", "/orgs/\(orgId)/tags", authed: true)
        return resp.tags
    }

    func members(orgId: String) async throws -> [CloudMember] {
        let resp: CloudMembersResponse = try await request("GET", "/orgs/\(orgId)/members", authed: true)
        return resp.members
    }

    /// Replace a conversation's assignees; returns the new assignee list.
    func setAssignees(orgId: String, conversationId: String, memberIds: [String]) async throws -> [CloudMember] {
        let resp: CloudAssigneesResponse = try await request("PUT", "/orgs/\(orgId)/conversations/\(conversationId)/assignees",
                                                             body: ["member_ids": memberIds], authed: true)
        return resp.assignees
    }

    /// RSVP to a meeting invite carried by a domain message. `status` is
    /// accepted|declined|tentative.
    func rsvp(orgId: String, messageId: String, status: String) async throws {
        try await requestVoid("POST", "/orgs/\(orgId)/messages/\(messageId)/rsvp", body: ["status": status], authed: true)
    }

    /// Answer a meet-link booking request. Accept creates the event and mails the
    /// visitor an ICS invite; decline mails them a no (with `reason`, if any).
    func answerMeetingRequest(orgId: String, requestId: String, accept: Bool, reason: String?) async throws {
        try await requestVoid("POST", "/orgs/\(orgId)/meeting-requests/\(requestId)/\(accept ? "accept" : "decline")",
                              body: accept ? [:] : ["reason": reason ?? ""], authed: true)
    }

    /// Put an emailed event (a PUBLISH .ics, which asks for no answer) onto the
    /// member's own calendar. No REPLY is sent — nobody asked for one.
    func importCalendarEvent(orgId: String, messageId: String) async throws {
        // A detected meeting's time is the sender's wall clock: the server reads it in our zone.
        try await requestVoid("POST", "/orgs/\(orgId)/messages/\(messageId)/calendar-import",
                              body: ["time_zone": TimeZone.current.identifier], authed: true)
    }

    /// Add an internal note to a conversation.
    func addNote(orgId: String, conversationId: String, body: String) async throws -> CloudNote {
        let resp: CloudNoteResponse = try await request("POST", "/orgs/\(orgId)/conversations/\(conversationId)/notes",
                                                        body: ["body": body], authed: true)
        return resp.note
    }

    // MARK: - Calendar zones (user-scoped, docs/iOS-App.md "Zones")

    /// The first call seeds the four defaults (Deep work / Prep / Admin / Personal).
    func zoneCategories() async throws -> [CloudZoneCategory] {
        let resp: CloudZoneCategoriesResponse = try await request("GET", "/account/zone-categories", authed: true)
        return resp.zoneCategories
    }

    func zones(startISO: String, endISO: String) async throws -> [CloudZone] {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let resp: CloudZonesResponse = try await request(
            "GET", "/account/zones?start=\(enc(startISO))&end=\(enc(endISO))", authed: true)
        return resp.zones
    }

    /// Create (`id == nil`) or patch a zone. `body` carries name/note/category_id/
    /// start_at/end_at/notify — partial on a patch.
    func saveZone(id: String?, body: [String: Any]) async throws -> CloudZone {
        let resp: CloudZoneResponse = try await request(
            id == nil ? "POST" : "PATCH", "/account/zones" + (id.map { "/\($0)" } ?? ""), body: body, authed: true)
        return resp.zone
    }

    func deleteZone(id: String) async throws {
        try await requestVoid("DELETE", "/account/zones/\(id)", authed: true)
    }

    /// Done on a zone card, shared with the user's other devices. Idempotent.
    func dismissZone(occurrenceId: String, endISO: String) async throws {
        try await requestVoid("POST", "/account/zone-dismissals",
                              body: ["occurrence_id": occurrenceId, "end_at": endISO], authed: true)
    }

    /// Create (`id == nil`) or patch a category: `{name?, color?}`.
    func saveZoneCategory(id: String?, body: [String: Any]) async throws -> CloudZoneCategory {
        let resp: CloudZoneCategoryResponse = try await request(
            id == nil ? "POST" : "PATCH", "/account/zone-categories" + (id.map { "/\($0)" } ?? ""), body: body, authed: true)
        return resp.zoneCategory
    }

    /// Its zones stay, uncategorised.
    func deleteZoneCategory(id: String) async throws {
        try await requestVoid("DELETE", "/account/zone-categories/\(id)", authed: true)
    }

    // MARK: - Blocked time (org-scoped, the member's own)

    func blockedTimes(orgId: String, startISO: String, endISO: String) async throws -> [CloudBlockedTime] {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let resp: CloudBlockedTimesResponse = try await request(
            "GET", "/orgs/\(orgId)/blocked-times?start=\(enc(startISO))&end=\(enc(endISO))", authed: true)
        return resp.blockedTimes
    }

    func createBlockedTime(orgId: String, startISO: String, endISO: String) async throws -> CloudBlockedTime {
        let resp: CloudBlockedTimeResponse = try await request(
            "POST", "/orgs/\(orgId)/blocked-times", body: ["start_at": startISO, "end_at": endISO], authed: true)
        return resp.blockedTime
    }

    func deleteBlockedTime(orgId: String, id: String) async throws {
        try await requestVoid("DELETE", "/orgs/\(orgId)/blocked-times/\(id)", authed: true)
    }

    // MARK: - Mail (write)

    /// Bulk lifecycle action: archive | trash | spam | mark_read | mark_unread | open.
    func bulk(orgId: String, conversationIds: [String], action: String) async throws {
        try await requestVoid("POST", "/orgs/\(orgId)/conversations/bulk",
                              body: ["conversation_ids": conversationIds, "action_name": action], authed: true)
    }

    /// Make a private label: only the caller sees it, and any member may make one.
    func createPrivateLabel(orgId: String, name: String) async throws -> CloudTag {
        let resp: CloudTagResponse = try await request("POST", "/orgs/\(orgId)/tags",
                                                       body: ["name": name, "private": true], authed: true)
        return resp.tag
    }

    /// Replace a conversation's tags (the server keeps other members' private labels).
    func setTags(orgId: String, conversationId: String, tagIds: [String]) async throws {
        try await requestVoid("PUT", "/orgs/\(orgId)/conversations/\(conversationId)/tags",
                              body: ["tag_ids": tagIds], authed: true)
    }

    /// Snooze a conversation until `untilISO` (it leaves the inbox, returns later).
    func snooze(orgId: String, conversationId: String, untilISO: String) async throws {
        try await requestVoid("POST", "/orgs/\(orgId)/conversations/\(conversationId)/snooze",
                              body: ["until": untilISO], authed: true)
    }

    func unsnooze(orgId: String, conversationId: String) async throws {
        try await requestVoid("DELETE", "/orgs/\(orgId)/conversations/\(conversationId)/snooze", authed: true)
    }

    /// Patch read/status on a single conversation.
    func updateConversation(orgId: String, id: String, read: Bool? = nil, status: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let read { body["read"] = read }
        if let status { body["status"] = status }
        try await requestVoid("PATCH", "/orgs/\(orgId)/conversations/\(id)", body: body, authed: true)
    }

    /// Send a message (new thread, or a reply when `conversationId` is set). Returns
    /// the created message id (for undo-send). `attachmentKeys` references
    /// pre-uploaded attachments (see `uploadAttachment`).
    @discardableResult
    func send(orgId: String, conversationId: String?, from: String, to: String, cc: String?,
              subject: String?, bodyPlain: String, bodyHtml: String?, attachmentKeys: [String] = []) async throws -> String {
        var body: [String: Any] = ["from_address": from, "to_address": to, "body_plain": bodyPlain]
        if let conversationId { body["conversation_id"] = conversationId }
        if let cc, !cc.isEmpty { body["cc_address"] = cc }
        if let subject { body["subject"] = subject }
        if let bodyHtml { body["body_html"] = bodyHtml; body["content_type"] = "text/html" }
        if !attachmentKeys.isEmpty { body["attachment_keys"] = attachmentKeys }
        let resp: CloudMessageResponse = try await request("POST", "/orgs/\(orgId)/messages", body: body, authed: true)
        return resp.message.id
    }

    /// Undo-send a message within the window (the server reverts it to a draft so
    /// the deferred delivery is skipped).
    func cancelSend(orgId: String, messageId: String) async throws {
        try await requestVoid("POST", "/orgs/\(orgId)/messages/\(messageId)/cancel-send", authed: true)
    }

    /// Create a draft (a stub message) so attachments can be uploaded against it
    /// before the real send. Returns the draft (carries its id + conversation_id).
    func createDraft(orgId: String, from: String, to: String, cc: String?, subject: String?,
                     bodyPlain: String, bodyHtml: String? = nil, conversationId: String?) async throws -> CloudMessage {
        var body: [String: Any] = ["from_address": from, "to_address": to, "body_plain": bodyPlain]
        if let bodyHtml { body["body_html"] = bodyHtml }
        if let conversationId { body["conversation_id"] = conversationId }
        if let cc, !cc.isEmpty { body["cc_address"] = cc }
        if let subject { body["subject"] = subject }
        let resp: CloudDraftResponse = try await request("POST", "/orgs/\(orgId)/drafts", body: body, authed: true)
        return resp.draft
    }

    /// The signature for each address the member may send as (spec 8.1.7).
    func signatures(orgId: String) async throws -> [String: MailSignature] {
        struct Response: Decodable { let applied: [String: MailSignature] }
        let r: Response = try await request("GET", "/orgs/\(orgId)/signatures", authed: true)
        return r.applied
    }

    func deleteDraft(orgId: String, draftId: String) async {
        _ = try? await requestVoid("DELETE", "/orgs/\(orgId)/drafts/\(draftId)", authed: true)
    }

    /// Schedule a draft for delivery at `sendAtISO` (the server defers it).
    func scheduleSend(orgId: String, draftId: String, sendAtISO: String) async throws {
        try await requestVoid("POST", "/orgs/\(orgId)/messages/\(draftId)/schedule",
                              body: ["send_at": sendAtISO], authed: true)
    }

    /// Upload a file against a (draft) message via multipart. Returns its key, to
    /// pass to `send(attachmentKeys:)`.
    func uploadAttachment(orgId: String, messageId: String, filename: String, mimeType: String, data: Data) async throws -> String {
        guard let token else { throw CloudError.notAuthenticated }
        guard let url = URL(string: Self.baseURL + "/orgs/\(orgId)/attachments") else {
            throw CloudError.transport("Bad URL")
        }
        let boundary = "inbox2-\(messageId)-\(data.count)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("message_id", messageId)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (respData, resp): (Data, URLResponse)
        do { (respData, resp) = try await URLSession.shared.data(for: req) }
        catch { throw CloudError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudError.http(code, "attachment upload failed")
        }
        let parsed = try Self.decoder.decode(CloudAttachmentResponse.self, from: respData)
        Log.cloud.info("[ffi] uploaded attachment \(filename) -> \(parsed.attachment.ref, privacy: .public)")
        return parsed.attachment.ref
    }

    // MARK: - Request plumbing

    private static let decoder = JSONDecoder()

    private func makeRequest(_ method: String, _ path: String, body: [String: Any]?, authed: Bool) throws -> URLRequest {
        guard let url = URL(string: Self.baseURL + path) else { throw CloudError.transport("Bad URL: \(path)") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed {
            guard let token else { throw CloudError.notAuthenticated }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return req
    }

    /// Send a request and decode the JSON body into `T`.
    func request<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, authed: Bool) async throws -> T {
        let data = try await send(method, path, body: body, authed: authed)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            Log.cloud.error("decode \(path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw CloudError.decoding("\(error)")
        }
    }

    /// Send a request, ignoring the body (for 204s).
    func requestVoid(_ method: String, _ path: String, body: [String: Any]? = nil, authed: Bool) async throws {
        _ = try await send(method, path, body: body, authed: authed)
    }

    private func send(_ method: String, _ path: String, body: [String: Any]?, authed: Bool) async throws -> Data {
        let req = try makeRequest(method, path, body: body, authed: authed)
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            Log.cloud.error("\(method, privacy: .public) \(path, privacy: .public) transport error: \(String(describing: error), privacy: .public)")
            throw CloudError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw CloudError.transport("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let msg = Self.errorMessage(from: data)
            Log.cloud.error("\(method, privacy: .public) \(path, privacy: .public) → \(http.statusCode) \(msg, privacy: .public)")
            throw CloudError.http(http.statusCode, msg)
        }
        Log.cloud.info("\(method, privacy: .public) \(path, privacy: .public) → \(http.statusCode)")
        return data
    }

    /// Pull a human message out of the API's `ErrorSerializer` shape (`{errors:[{message}]}`).
    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let errs = obj["errors"] as? [[String: Any]], let m = errs.first?["message"] as? String { return m }
        if let m = obj["error"] as? String { return m }
        return ""
    }
}
