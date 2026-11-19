import SwiftUI
import Combine
import UIKit

/// App-level driver for "read this mail aloud, then offer to file it" — shared by the
/// message reader's speaker button and the inbox row's "Read aloud" action, so both
/// surfaces run the exact same flow without leaving the screen they're on.
///
/// Lifecycle: `.thinking` while the email-to-voice summary is generated → `.speaking`
/// while the shared `Speaker` streams it (with the Bridge-style "trash or archive?"
/// question appended) → `.listening` for a 5s hands-free window after. The on-device
/// `TriageListener` is armed for the whole spoken stretch (break in any time) and the
/// window; a matched keyword calls back the host (`onTriage`) to apply the action — the
/// reader dismisses, the inbox animates the row out. A spoken "no/cancel", a second tap,
/// or the window elapsing closes it silently.
@MainActor
final class ReadAloudController: ObservableObject {
    enum Phase { case idle, thinking, speaking, listening }
    @Published private(set) var phase: Phase = .idle
    /// The thread being read, so per-row / per-reader UI can light up just for it.
    @Published private(set) var conversationId: String?

    /// The spoken question appended after the mail — mirrors the Bridge's offer to file
    /// a thread. The keywords are exactly those `TriageListener` matches.
    static let triagePrompt = "\n\nWould you like to trash it or archive it?"

    let triage = TriageListener()
    private let brain = BridgeBrain()

    private weak var speaker: Speaker?
    private weak var presence: VoicePresence?
    private weak var engine: EngineModel?
    private weak var voice: VoiceEngineManager?
    private var onTriage: ((ConversationAction) -> Void)?

    private var readTask: Task<Void, Never>?
    private var listenWindowTask: Task<Void, Never>?
    private var speakerCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    /// True for a real read (triage armed); false for the plain "Speak with" tester.
    private var armed = false

    init() {
        triage.onTriage = { [weak self] action in self?.handleTriage(action) }
        triage.onCancel = { [weak self] in self?.stop() }
        // Route the listener's mic level to the shared meter sink — observed only by the
        // listening orb/pill, so a level tick doesn't re-render every reader/inbox that
        // observes this controller for its phase.
        triage.$level.sink { v in AudioLevels.shared.setMic(v) }.store(in: &cancellables)
    }

    /// True while this controller is reading the given thread (drives per-surface UI).
    func isActive(_ id: String) -> Bool { conversationId == id && phase != .idle }

    /// Start the read-aloud + voice triage for a thread, staying on the current screen.
    /// `onTriage` is called with the spoken action so the host applies it (reader pops,
    /// inbox removes the row).
    func start(convo: Conversation, engine: EngineModel, voice: VoiceEngineManager,
               speaker: Speaker, presence: VoicePresence,
               onTriage: @escaping (ConversationAction) -> Void) {
        stop()   // supersede any read in flight
        self.engine = engine; self.voice = voice
        self.speaker = speaker; self.presence = presence
        self.onTriage = onTriage
        conversationId = convo.id
        armed = true
        // Speak on the SAME clean playback-only session as "Speak with" — NOT the
        // `.playAndRecord` dialog session: its voice-processing/AEC path audibly
        // degrades the synthesized voice, which made this read sound mangled next
        // to the menu reading the identical text. The trade: no spoken break-in
        // DURING the read (tap the button/orb to stop); the mic opens right after
        // the question for the hands-free answer window instead.
        speaker.dialogMode = false
        presence.readingConversationId = convo.id
        observeSpeaker(speaker)
        withAnimation(.easeIn(duration: 0.2)) { phase = .thinking }
        readTask = Task {
            // Speak the stored triage summary — the same text as "Speak with → Small"
            // (falling back to Medium): instant, deterministic, and identical to what
            // the user reads on screen. The generated email-to-voice path is only the
            // fallback for threads the triage worker hasn't summarized yet — the
            // on-device lane's freeform output is too uneven to be the default read.
            let short = convo.aiSummaryShort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let medium = convo.aiSummaryMedium?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stored = short.isEmpty ? (medium.isEmpty ? nil : medium) : short
            Log.engine.info("read-aloud start convo=\(convo.id, privacy: .public) source=\(short.isEmpty ? (medium.isEmpty ? "generated" : "stored-medium") : "stored-short", privacy: .public) shortChars=\(short.count) mediumChars=\(medium.count)")
            let result: BridgeBrain.BridgeReply = if let stored {
                .ok(stored)
            } else {
                await brain.emailVoice(conversationKey: convo.id, engine: engine, manager: voice)
            }
            if Task.isCancelled { return }
            if case .ok(let text) = result {
                Log.engine.info("read-aloud speaking: \(String(text.prefix(120)))")
            }
            switch result {
            case .ok(let text):
                phase = .speaking
                // Plain playback — identical to the "Speak with" path, so the read
                // sounds the same. The triage spotter is armed AFTER speech ends
                // (beginListenWindow), so its voice-processing engine never touches
                // playback.
                speaker.speak(text + Self.triagePrompt, using: voice, engine: engine, surface: .reader)
            case .openAIError(let msg):
                armed = false   // no triage behind an error read-out
                phase = .speaking
                speaker.speakSystem("OpenAI returned the error: \(msg). Go into settings and update or disable your key.")
            case .notReady:
                finishIdle()
            }
            readTask = nil
        }
    }

    /// Speak a specific text verbatim (the reader's "Speak with" tester) — same playing
    /// state, but no triage prompt or listener.
    func speakPlain(_ text: String, convo: Conversation, engine: EngineModel,
                    voice: VoiceEngineManager, speaker: Speaker, presence: VoicePresence) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Log.engine.info("read-aloud speakPlain convo=\(convo.id, privacy: .public) chars=\(t.count) text: \(String(t.prefix(120)))")
        stop()
        self.speaker = speaker; self.presence = presence
        conversationId = convo.id
        armed = false
        speaker.dialogMode = false
        presence.readingConversationId = convo.id
        observeSpeaker(speaker)
        withAnimation(.easeIn(duration: 0.2)) { phase = .speaking }
        speaker.speak(t, using: voice, engine: engine, surface: .reader)
    }

    /// Stop everything (a second tap / a new read / a spoken cancel) and cut any speech.
    func stop() {
        readTask?.cancel(); readTask = nil
        speaker?.stop()
        finishIdle()
    }

    // MARK: - internals

    /// React to the shared speaker: open the keyword mic once playback is live, then
    /// hold it open for a triage window when speech ends (or retire on a plain read).
    private func observeSpeaker(_ speaker: Speaker) {
        // `dropFirst` skips @Published's replay of the current value on subscription —
        // we only want the real transitions (playback starting, then ending) that follow.
        speakerCancellable = speaker.$isSpeaking
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] speaking in self?.speakerChanged(speaking) }
    }

    private func speakerChanged(_ speaking: Bool) {
        if !speaking && !(speaker?.isPreparing ?? false) && phase == .speaking {
            if armed { beginListenWindow() } else { finishIdle() }
        }
    }

    /// Speech ended on a real read → NOW open the mic (the spotter stays off during
    /// playback so its voice-processing path can't degrade the read) and hold it for
    /// a hands-free answer. If the listener can't come up (no permission) the read
    /// just retires; the window restarts its 5s once listening is live.
    private func beginListenWindow() {
        // The spotter's engine records — it needs the `.playAndRecord` session the
        // speech deliberately avoided (clean playback). Playback is over, so the
        // session flip can't degrade anything now.
        speaker?.prepareDialogSession()
        triage.start()
        listenWindowTask?.cancel()
        listenWindowTask = Task { @MainActor in
            // The spotter's engine takes a beat to come up — give it up to a second
            // before deciding the mic isn't available.
            for _ in 0..<20 where !triage.isListening {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            guard triage.isListening else { finishIdle(); return }
            withAnimation(.easeInOut(duration: 0.25)) { phase = .listening }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            finishIdle()
        }
    }

    private func handleTriage(_ action: ConversationAction) {
        let cb = onTriage
        readTask?.cancel(); readTask = nil
        speaker?.stop()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finishIdle()
        cb?(action)
    }

    /// Tear down the listener / window and return to idle, WITHOUT force-stopping speech
    /// (speech is already over, or the caller stopped it). `stop()` adds the speech cut.
    private func finishIdle() {
        armed = false
        listenWindowTask?.cancel(); listenWindowTask = nil
        speakerCancellable = nil
        triage.stop()
        speaker?.dialogMode = false
        onTriage = nil
        conversationId = nil
        withAnimation(.easeOut(duration: 0.25)) { phase = .idle }
    }
}
