import Foundation

// Send to… on the phone (docs/MCP-Client.md, TODO 48.14). Decodes the JSON the core's
// `mcp_*` FFI hands back. Draft-only: a tool runs only from the Create button.

struct McpPreset: Decodable, Identifiable, Hashable {
    let name: String
    let url: String
    let auth: String   // "oauth" | "token" | "client_id"
    var id: String { name }
}

struct McpConnection: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    let auth: String
    let status: String
    let error: String?
    var needsAuth: Bool { status == "needs_auth" }
}

struct McpField: Decodable, Hashable {
    let key: String
    let label: String
    let description: String
    let kind: String     // string | number | integer | boolean | enum | json
    let options: [String]
    let required: Bool
}

struct McpDraft: Decodable, Identifiable, Hashable {
    let name: String
    let description: String
    let fields: [McpField]
    var values: [String: String]
    var id: String { name }
}

/// What Send to… made for a Lore item (the chip on the row), from `lore_sent_*`.
struct LoreSentRef: Decodable, Hashable {
    let itemKey: String
    let connectionName: String
    let reference: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case reference, url
        case itemKey = "item_key"
        case connectionName = "connection_name"
    }

    /// The item key the desktop uses too (web `uid`): `mx:conv_…` or `local:conv_…`.
    static func key(for c: Conversation) -> String { "\(c.isDomain ? "mx" : "local"):\(c.id)" }

    var chipLabel: String { reference ?? "Sent to \(connectionName)" }
}

/// One Lore item as the prefill input (`mcp_drafts_json`): only what the row shows.
struct McpItem: Encodable {
    let subject: String
    let detail: String
    let from: String
    let address: String
    let domain: String

    init(_ c: Conversation) {
        subject = c.subject
        detail = c.preview
        from = c.sender
        address = c.email
        domain = LoreText.orgDomain(c.email) ?? ""
    }
}

/// The core's Send-to calls, off the main thread (each blocks on the network).
@MainActor
enum McpClient {
    private static var engine: InboxEngine? { EngineModel.shared.mxEngine }

    static func run<T: Sendable>(_ body: @Sendable @escaping (InboxEngine) throws -> T) async throws -> T {
        guard let engine else { throw McpFailure.unavailable }
        return try await Task.detached { try body(engine) }.value
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func sent() async -> [LoreSentRef] {
        guard let json = try? await run({ try $0.loreSentListJson() }),
              let rows = try? decode([LoreSentRef].self, json) else { return [] }
        return rows
    }
}

enum McpFailure: LocalizedError {
    case unavailable, stateMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The app is still starting. Try again."
        case .stateMismatch: return "The sign-in did not come back correctly. Try again."
        }
    }
}
