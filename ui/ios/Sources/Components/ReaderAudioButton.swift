import SwiftUI

/// The message reader's toolbar "Read aloud" button. Pulled out of `MessageView` so it —
/// not the whole reader — owns the high-frequency audio-level observation (`AudioLevels`):
/// the speaking audio graph and the listening mic pulse. Tap once to read the thread aloud
/// (then the hands-free triage window); tap again at any phase to stop.
struct ReaderAudioButton: View {
    let convo: Conversation
    /// Applied when a spoken triage keyword lands (host pops the reader for trash/archive).
    let onTriage: (ConversationAction) -> Void

    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var voice: VoiceEngineManager
    @EnvironmentObject private var speaker: Speaker
    @EnvironmentObject private var presence: VoicePresence
    @EnvironmentObject private var readAloud: ReadAloudController
    @ObservedObject private var levels = AudioLevels.shared

    /// `.idle` unless the shared controller is reading *this* thread, so the button lights
    /// up only for the open conversation.
    private var readPhase: ReadAloudController.Phase {
        readAloud.isActive(convo.id) ? readAloud.phase : .idle
    }

    var body: some View {
        Button { toggle() } label: {
            if readPhase == .idle {
                Image(systemName: "speaker.wave.2.fill")
                    .font(AppFont.title3)
                    .contentTransition(.symbolEffect(.replace))
            } else if readPhase == .listening {
                // Waiting for a spoken triage answer: a pink mic glyph that pulses with the
                // live level so the slot reads as "your turn", not "still playing".
                Image(systemName: "mic.fill")
                    .font(AppFont.title3)
                    .foregroundStyle(kPink)
                    .scaleEffect(1 + levels.mic * 0.25)
                    .animation(.easeOut(duration: 0.12), value: levels.mic)
            } else if speaker.isSpeaking {
                // Playing: the speaker icon becomes a live audio graph (the big visual is
                // the standard shared orb, root-level/centered — same as every screen).
                VoiceBars(level: levels.speaker)
                    .frame(width: 24, height: 22)
            } else {
                // Summarizing (or fetching the voice): a spinner where the icon was, so the
                // slot never reads as empty.
                GradientSpinner(size: 18)
            }
        }
        .accessibilityLabel(readPhase == .idle ? "Read aloud" : readPhase == .listening ? "Listening for a triage command" : "Stop reading")
    }

    /// Tap once → the shared controller reads the thread aloud, then offers to file it
    /// (trash / archive) hands-free. Tap again at any phase → stop.
    private func toggle() {
        if readPhase != .idle {
            readAloud.stop()
            return
        }
        readAloud.start(convo: convo, engine: engine, voice: voice,
                        speaker: speaker, presence: presence) { onTriage($0) }
    }
}
