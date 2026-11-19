import Foundation

/// App ⇄ Share-Extension hand-off over the App Group container. The extension hosts its
/// own compose UI and can't reach the app's engine/credentials, so:
///
/// - **App → extension** (`Context`): the From-identity list + the domain (mx) session
///   token + API base, mirrored by the app so the extension's picker + domain send work.
/// - **Extension → app** (`QueuedSend`): a durable send the app must deliver — every
///   connected-channel (Gmail/IMAP/Microsoft) send, plus any domain send the extension
///   couldn't complete via REST (e.g. offline). The app drains these on foreground /
///   background refresh via its engine + cloud send paths.
///
/// Domain sends normally go straight from the extension via the reused `CloudClient`, so
/// they never become `QueuedSend`s. Attachments are COPIED into a per-send directory
/// (never read into memory in the extension — a shared video would blow its ~120 MB limit).
///
/// Compiled into BOTH targets — keep it dependency-free (Foundation only).
enum ShareBridge {
    /// Must match `com.apple.security.application-groups` in both entitlements files.
    static let appGroupId = "group.com.inbox2.ios"

    // MARK: Contracts

    /// A sendable "from" identity, mirrored from the app's compose From picker.
    struct Identity: Codable, Hashable {
        let key: String       // account key (offline channel) or `org_…` id (domain)
        let email: String
        let label: String
        let isDomain: Bool
    }

    /// A recipient suggestion for To/Cc/Bcc autocomplete (name + email).
    struct Contact: Codable, Hashable {
        let name: String
        let email: String
    }

    /// What the app mirrors for the extension to compose + send.
    struct Context: Codable {
        var identities: [Identity]
        var token: String?    // domain (mx) session token, for direct REST send
        var apiBase: String
        var contacts: [Contact] = []
    }

    /// A staged attachment (bytes live as a file at `relativePath` in the send dir).
    struct Attachment: Codable, Hashable, Identifiable {
        let filename: String
        let mimeType: String?
        let relativePath: String
        var size: Int = 0
        var id: String { relativePath }
    }

    /// A composed message the app must deliver (connected channel, or domain fallback).
    struct QueuedSend: Codable {
        let id: String
        let isDomain: Bool
        let accountKey: String   // `org_…` (domain) or account key (offline channel)
        let fromEmail: String
        let to: String
        let cc: String?
        let bcc: String?
        let subject: String?
        let bodyPlain: String?
        let conversationId: String?
        let attachments: [Attachment]
    }

    // MARK: Locations

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }
    private static var contextURL: URL? { container?.appendingPathComponent("share-context.json") }
    private static var sendsDir: URL? { container?.appendingPathComponent("queued-sends", isDirectory: true) }
    private static let manifestName = "send.json"

    // MARK: Context (app → extension)

    static func writeContext(_ c: Context) {
        guard let url = contextURL, let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: url)
    }

    static func readContext() -> Context? {
        guard let url = contextURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Context.self, from: data)
    }

    // MARK: Staging a compose's attachments (extension)

    /// Create a fresh per-send directory. Returns its id + URL.
    static func newSendDir() -> (id: String, dir: URL)? {
        guard let base = sendsDir else { return nil }
        let id = "snd_" + UUID().uuidString
        let dir = base.appendingPathComponent(id, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return (id, dir)
    }

    /// The directory for a staged send (so callers can add more files into it).
    static func sendDir(id: String) -> URL? {
        sendsDir?.appendingPathComponent(id, isDirectory: true)
    }

    /// Copy a shared file into a send dir (streamed — no full read into memory).
    /// `src` is the temp URL from `loadFileRepresentation`; copy before it returns.
    static func copyIn(_ src: URL, mimeType: String?, index: Int, into dir: URL) -> Attachment? {
        let base = src.lastPathComponent.isEmpty ? "attachment-\(index)" : src.lastPathComponent
        let rel = "\(index)-\(base)"
        let dest = dir.appendingPathComponent(rel)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Attachment(filename: base, mimeType: mimeType, relativePath: rel, size: size)
        } catch { return nil }
    }

    /// Discard a send dir (after a successful immediate domain send, or a cancel).
    static func discard(id: String) {
        guard let base = sendsDir else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent(id, isDirectory: true))
    }

    /// Commit a staged send as a durable queued job (writes the manifest into its dir).
    static func enqueue(_ send: QueuedSend) {
        guard let base = sendsDir, let data = try? JSONEncoder().encode(send) else { return }
        let dir = base.appendingPathComponent(send.id, isDirectory: true)
        try? data.write(to: dir.appendingPathComponent(manifestName))
    }

    /// Load the bytes for staged attachments in a given send dir (extension: for an
    /// immediate domain send; app: for draining a queued send).
    static func loadAttachments(id: String, _ attachments: [Attachment]) -> [OutgoingItem] {
        guard let base = sendsDir else { return [] }
        let dir = base.appendingPathComponent(id, isDirectory: true)
        return attachments.compactMap { a in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(a.relativePath)) else { return nil }
            return OutgoingItem(filename: a.filename, mimeType: a.mimeType, data: data)
        }
    }

    /// A loaded attachment ready for FFI / REST.
    struct OutgoingItem {
        let filename: String
        let mimeType: String?
        let data: Data
    }

    // MARK: Draining (app)

    /// All committed queued sends (dirs that hold a manifest).
    static func pending() -> [QueuedSend] {
        guard let base = sendsDir,
              let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)) else { return nil }
            return try? JSONDecoder().decode(QueuedSend.self, from: data)
        }
    }

    static func remove(_ id: String) { discard(id: id) }

    /// Drop staged-but-uncommitted dirs (compose abandoned / extension killed mid-edit)
    /// older than `seconds` so an orphaned video can't sit in the container forever.
    static func gcOrphans(olderThan seconds: TimeInterval = 3600) {
        guard let base = sendsDir,
              let dirs = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let now = Date()
        for dir in dirs {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(manifestName).path) { continue }
            guard let m = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(m) > seconds else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
