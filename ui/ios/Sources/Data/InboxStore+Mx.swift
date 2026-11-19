import Foundation
import SQLite3

/// Reads of the MX mirror — inbox2-hosted mail the Rust engine keeps in the `mx_*`
/// tables (docs/MX-Sync.md). Each row's `payload` is the API's own JSON, so these
/// return response-shaped `Data` and the existing cloud DTOs decode it: the caller
/// can't tell the mirror from the endpoint. Mirrors `ui/web/src/lib/localData.js`.
///
/// `nil` means "can't answer this locally" (not mirrored, history still being
/// read, a filter only the server can evaluate) — never "empty".
extension InboxStore {
    /// The mirrored org's key for a key-or-slug. `complete` also requires history to
    /// be fully read — a partial page would silently miss mail. Always scoped to the
    /// signed-in user: visibility is per member.
    func mxOrg(_ orgIdOrSlug: String, userKey: String, complete: Bool = true) -> String? {
        queue.sync {
            run("""
                SELECT s.organization_id FROM mx_sync_state s
                WHERE s.user_key = ?2 \(complete ? "AND s.backfill_done = 1" : "")
                  AND (s.organization_id = ?1 OR EXISTS (
                    SELECT 1 FROM mx_directory d
                    WHERE d.organization_id = s.organization_id AND d.type = 'organization'
                      AND json_extract(d.payload, '$.slug') = ?1))
                """, binds: [orgIdOrSlug, userKey]) { String(cString: sqlite3_column_text($0, 0)) }.first
        }
    }

    /// `{"conversations": [...]}` — the org pool, newest first. Same defaults as the
    /// API: no status hides trash / spam / archived.
    /// Callers don't page, so one page is as deep as the channel lists go (200).
    func mxConversations(org: String, status: String?, read: Bool?, domain: String?, page: Int, perPage: Int = 200,
                         labeledOnly: Bool = false) -> Data {
        var conditions = ["organization_id = ?"]
        var binds = [org]
        // Lore: triage-labelled rows only, before the page limit (so unlabelled mail can't push them out).
        if labeledOnly { conditions.append("json_extract(payload, '$.triage_label') IS NOT NULL AND json_extract(payload, '$.triage_label') <> 'resolved'") }
        if let status {
            conditions.append("status = ?"); binds.append(status)
        } else {
            conditions.append("status NOT IN ('trash', 'spam', 'archived')")
            // The Inbox skips sent-only threads; Lore's Waiting list needs them.
            if !labeledOnly { conditions.append("COALESCE(json_extract(payload, '$.sent_only'), 0) = 0") }
        }
        if let read { conditions.append("read = ?"); binds.append(read ? "1" : "0") }
        if let domain {
            conditions.append("""
                (domain_key = ? OR domain_key IN (SELECT key FROM mx_directory WHERE organization_id = ? AND type = 'domains'
                   AND (json_extract(payload, '$.slug') = ? OR json_extract(payload, '$.name') = ?)))
                """)
            binds += [domain, org, domain, domain]
        }
        binds += [String(perPage), String(max(page - 1, 0) * perPage)]
        let rows = queue.sync {
            run("""
                SELECT payload FROM mx_conversations WHERE \(conditions.joined(separator: " AND "))
                ORDER BY updated_at DESC, key DESC LIMIT ? OFFSET ?
                """, binds: binds, Self.payload)
        }
        return Self.wrap("conversations", rows)
    }

    /// `{"conversation": {…, "messages": [...], "notes": [...]}}` for a thread whose
    /// children are all here; `nil` for one held only as a list row.
    func mxConversationDetail(org: String, id: String) -> Data? {
        queue.sync {
            guard let row = run("SELECT payload FROM mx_conversations WHERE key = ?1 AND organization_id = ?2 AND hydrated = 1",
                                binds: [id, org], Self.payload).first,
                  var conversation = Self.object(row) else { return nil }
            func children(_ table: String) -> [Any] {
                run("SELECT payload FROM \(table) WHERE conversation_key = ?1 ORDER BY created_at ASC, key ASC",
                    binds: [id], Self.payload).compactMap(Self.object)
            }
            conversation["messages"] = run("SELECT payload, plain FROM mx_messages WHERE conversation_key = ?1 ORDER BY created_at ASC, key ASC",
                                           binds: [id], Self.message).compactMap { $0 }
            conversation["notes"] = children("mx_notes")
            // The list row names assignees compactly; the detail endpoint returns the
            // full member. Same people — take the richer record from the directory.
            let members = run("SELECT payload FROM mx_directory WHERE organization_id = ?1 AND type = 'members'",
                              binds: [org], Self.payload).compactMap(Self.object)
            let byId = Dictionary(members.compactMap { m in (m["id"] as? String).map { ($0, m) } }, uniquingKeysWith: { a, _ in a })
            if let compact = conversation["assignees"] as? [[String: Any]] {
                conversation["assignees"] = compact.map { a in (a["id"] as? String).flatMap { byId[$0] } ?? a }
            }
            return try? JSONSerialization.data(withJSONObject: ["conversation": conversation])
        }
    }

    /// `{"<type>": [...]}` — a directory listing (`tags`, `members`, `domains`, …)
    /// exactly as its index endpoint returned it, in the server's order.
    func mxDirectory(org: String, type: String) -> Data {
        let rows = queue.sync {
            run("SELECT payload FROM mx_directory WHERE organization_id = ?1 AND type = ?2 ORDER BY position",
                binds: [org, type], Self.payload)
        }
        return Self.wrap(type, rows)
    }

    private static func payload(_ stmt: OpaquePointer) -> String { String(cString: sqlite3_column_text(stmt, 0)) }

    /// A message row. Opened sealed mail keeps ciphertext in `payload` and its text
    /// in `plain`: put the text in the fields the API would have filled.
    private static func message(_ stmt: OpaquePointer) -> [String: Any]? {
        guard var m = object(String(cString: sqlite3_column_text(stmt, 0))) else { return nil }
        guard let text = sqlite3_column_text(stmt, 1), let opened = object(String(cString: text)) else { return m }
        let header = opened["header"] as? [String: Any] ?? [:]
        let body = opened["body"] as? [String: Any] ?? [:]
        let fields = [("subject", header["subject"]), ("from_address", header["from"]), ("to_address", header["to"]),
                      ("cc_address", header["cc"]), ("body_plain", body["plain"]), ("body_html", body["html"])]
        for case let (name, value as String) in fields where !value.isEmpty { m[name] = value }
        m["body_plain"] = m["body_plain"] ?? ""   // an empty mail is opened, not locked
        return m
    }

    private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// Payloads are already JSON: splice them rather than parse and re-encode.
    private static func wrap(_ key: String, _ payloads: [String]) -> Data {
        Data("{\"\(key)\":[\(payloads.joined(separator: ","))]}".utf8)
    }
}
