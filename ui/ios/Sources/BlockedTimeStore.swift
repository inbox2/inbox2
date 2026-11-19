import Foundation

/// The member's blocked-time windows ("Block time" on the Day timeline) — busy in
/// every free/busy read, deliberately not calendar events. MX/org-scoped, so they
/// only exist signed in with an org (docs/Calendar.md "Meet links").
@MainActor
final class BlockedTimeStore: ObservableObject {
    static let shared = BlockedTimeStore()

    /// Every block fetched so far, by id — each day window replaces its slice.
    @Published private(set) var blocks: [String: CloudBlockedTime] = [:]

    private var cloud: CloudSession { CloudSession.shared }
    private var orgId: String? { cloud.isSignedIn ? cloud.currentOrg?.id : nil }
    var enabled: Bool { orgId != nil }

    func blocks(from: Date, to: Date) -> [CloudBlockedTime] {
        blocks.values.filter { $0.start < to && $0.end > from }.sorted { $0.start < $1.start }
    }

    /// Silent on failure — blocks are an overlay, like zones.
    func load(from: Date, to: Date) async {
        guard let orgId else { return }
        do {
            let fetched = try await cloud.mailClient().blockedTimes(
                orgId: orgId, startISO: isoLocalInternet.string(from: from), endISO: isoLocalInternet.string(from: to))
            var next = blocks.filter { !($0.value.start < to && $0.value.end > from) }
            for b in fetched { next[b.id] = b }
            blocks = next
        } catch {
            Log.cloud.warning("blocked times load failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Returns an error message, nil on success.
    func create(_ range: Range<Date>) async -> String? {
        guard let orgId else { return "Sign in to block time." }
        do {
            let b = try await cloud.mailClient().createBlockedTime(
                orgId: orgId, startISO: isoLocalInternet.string(from: range.lowerBound),
                endISO: isoLocalInternet.string(from: range.upperBound))
            blocks[b.id] = b
            return nil
        } catch {
            return (error as? CloudError)?.errorDescription ?? error.localizedDescription
        }
    }

    func delete(_ block: CloudBlockedTime) async -> String? {
        guard let orgId else { return "Sign in to remove blocked time." }
        do {
            try await cloud.mailClient().deleteBlockedTime(orgId: orgId, id: block.id)
            blocks[block.id] = nil
            return nil
        } catch {
            return (error as? CloudError)?.errorDescription ?? error.localizedDescription
        }
    }
}
