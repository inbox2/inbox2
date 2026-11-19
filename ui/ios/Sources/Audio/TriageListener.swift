import Combine
import SwiftUI

/// Hands-free triage for the message reader: while a thread is being read aloud — and
/// for a few seconds after — keep the mic open and listen for a short triage keyword
/// ("trash" / "archive") so the user can file the mail without reaching for the
/// screen, the way the Bridge offers to file a thread.
///
/// A thin vocabulary over the shared `KeywordSpotter` break-in engine (which owns the
/// mic capture, echo cancellation and on-device recognition): this layer resolves the
/// matched word to a `ConversationAction` and mirrors the mic `level` for the
/// listening orb. If the spotter is unavailable it simply no-ops, so this is a purely
/// additive convenience layer: the reader's overflow menu still applies every action
/// by hand.
@MainActor
final class TriageListener: ObservableObject {
    /// Smoothed mic level, 0…1 — drives the listening orb while we wait for an answer.
    @Published private(set) var level: Double = 0
    @Published private(set) var isListening = false

    /// Single spoken keyword → the conversation action it triages. Scanned newest-word
    /// first so only a freshly-spoken word fires. Several spellings map to the same
    /// action (e.g. "delete"/"bin" → trash) for natural phrasing.
    static let commands: [(word: String, action: ConversationAction)] = [
        ("trash", .trash),
        ("delete", .trash),
        ("bin", .trash),
        ("archive", .archive),
    ]
    /// Spoken dismissals that close the prompt without filing anything: triage-specific
    /// phrasing ("no thanks", "leave it") plus the universal stop-words, so "ok"/"stop"
    /// interrupts a read-aloud exactly like it interrupts the Bridge.
    static let cancelWords: Set<String> =
        KeywordSpotter.stopWords.union(["no", "nope", "nothing", "skip", "leave", "dismiss", "never"])
    private static let actionWords = Set(commands.map(\.word))

    /// Called with the matched action the first time a keyword is heard in a run.
    var onTriage: ((ConversationAction) -> Void)?
    /// Called the first time a dismissal word is heard — close without acting.
    var onCancel: (() -> Void)?

    /// Asks for mic + speech permission on start (the reader can be the user's first
    /// voice interaction) and meters the mic for the orb.
    private let spotter = KeywordSpotter(vocabulary: actionWords.union(cancelWords),
                                         asksPermission: true, metersLevel: true)
    private var cancellables = Set<AnyCancellable>()

    init() {
        spotter.onKeyword = { [weak self] word in self?.route(word) }
        // Mirror the spotter's published state so observers of this object re-render.
        spotter.$level.sink { [weak self] v in self?.level = v }.store(in: &cancellables)
        spotter.$isListening.sink { [weak self] v in self?.isListening = v }.store(in: &cancellables)
    }

    func start() { spotter.start() }
    func stop() { spotter.stop() }

    private func route(_ word: String) {
        if let cmd = Self.commands.first(where: { $0.word == word }) {
            onTriage?(cmd.action)
        } else {
            onCancel?()
        }
    }
}
