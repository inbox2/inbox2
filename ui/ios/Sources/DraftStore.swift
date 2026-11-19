import SwiftUI

/// A locally-saved compose draft. External-channel drafts are local on the desktop
/// too (the core has no mail save-draft path), so iOS persists them on-device and
/// they survive app restarts.
struct SavedDraft: Identifiable, Codable, Hashable {
    var id = UUID()
    var fromAccountKey: String?
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var savedAt = Date()

    var titleLine: String { subject.isEmpty ? "(No subject)" : subject }
    var previewLine: String {
        let recip = to.isEmpty ? "No recipient" : "To: \(to)"
        let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? recip : "\(recip) · \(snippet.prefix(60))"
    }
}

/// Persists local drafts to UserDefaults (JSON). Injected via the environment;
/// ComposeView writes, the Drafts folder lists.
@MainActor
final class DraftStore: ObservableObject {
    @Published private(set) var drafts: [SavedDraft] = []
    private static let key = "inbox2_drafts"

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let arr = try? JSONDecoder().decode([SavedDraft].self, from: data) else { return }
        drafts = arr.sorted { $0.savedAt > $1.savedAt }
    }

    /// Insert or update a draft (stamped with the current time), newest first.
    func save(_ draft: SavedDraft) {
        var copy = draft
        copy.savedAt = Date()
        if let i = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[i] = copy
        } else {
            drafts.append(copy)
        }
        persist()
        Log.action.info("saved draft \(copy.id.uuidString, privacy: .public)")
    }

    func delete(id: UUID) {
        drafts.removeAll { $0.id == id }
        persist()
        Log.action.info("deleted draft \(id.uuidString, privacy: .public)")
    }

    private func persist() {
        drafts.sort { $0.savedAt > $1.savedAt }
        if let data = try? JSONEncoder().encode(drafts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
