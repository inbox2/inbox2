import AVFoundation
import Foundation

/// A tiny shared sink for the live audio meters — the TTS playback amplitude and the
/// read-aloud/triage mic level. Split out of `Speaker` / `ReadAloudController` so their
/// audio-frame-rate level updates only re-render the small views that actually draw a
/// meter (`VoiceBars`, the orb, the listening pill) — not every screen that merely
/// observes those controllers for `isSpeaking` / `phase`.
///
/// The reader's toolbar was the casualty: `MessageView` observes both controllers, so a
/// level tick redrew the whole body, flickering the open actions menu and cancelling its
/// press-drag gesture. Now the controllers publish `isSpeaking`/`phase` (rare) while the
/// meter values flow through here, observed only where a meter is shown.
@MainActor
final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()

    /// TTS playback level (0…1) — drives the speaking audio graph / orb waveform.
    @Published private(set) var speaker: Double = 0
    /// Read-aloud / triage mic level (0…1) — drives the listening orb + pill.
    @Published private(set) var mic: Double = 0

    func setSpeaker(_ v: Double) { if v != speaker { speaker = v } }
    func setMic(_ v: Double) { if v != mic { mic = v } }

    private init() {}
}

/// Mic-level math shared by every capture tap (`KeywordSpotter`, `ListeningManager`).
enum MicLevel {
    /// RMS of the first channel (typically ~0…0.3 for speech).
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { let s = ch[i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }

    /// Map RMS to 0…1 and smooth the running `level` toward it.
    static func smooth(_ level: Double, rms: Float) -> Double {
        level * 0.6 + min(1.0, Double(rms) * 6.0) * 0.4
    }
}
