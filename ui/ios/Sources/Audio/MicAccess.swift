import AVFoundation
import Speech

/// The microphone / on-device-speech access state the Bridge surfaces to the user.
/// `granted` is the quiet happy path; `denied` and `unavailable` drive a small inline
/// status badge on the Bridge screen (see `BridgeView`).
enum MicAccess: Equatable {
    /// Mic (and speech, when needed) authorized — talk-to-the-Bridge works.
    case granted
    /// The user refused mic or speech permission — re-enable in Settings.
    case denied
    /// No usable microphone / on-device recognizer on this device.
    case unavailable

    /// A short, user-facing line for the Bridge status badge. `nil` when granted.
    var statusText: String? {
        switch self {
        case .granted: return nil
        case .denied: return "Mic access is off. Turn it on in Settings to talk to the Bridge."
        case .unavailable: return "This device has no mic."
        }
    }
}

/// Mic + on-device speech authorization, resolved once and reported as a `MicAccess`.
/// Shared by push-to-talk capture (`ListeningManager`) and the barge-in spotter
/// (`KeywordSpotter`, via the Bridge) so both request the same way and surface the same
/// denial / unavailability state. Requesting when already determined never re-prompts —
/// granted returns immediately, so it's cheap to call before every utterance.
enum MicPermission {
    /// Whether the device can do on-device speech recognition at all (hardware + model).
    /// The barge-in spotter (still SFSpeechRecognizer-based) requires this; the Bridge
    /// STT lanes (SpeechAnalyzer / OpenAI) do not.
    static func recognizerAvailable() -> Bool {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { return false }
        return r.isAvailable
    }

    /// Request mic (always) and speech (when `needsSpeech`) authorization, reporting the
    /// resolved access state on the main actor.
    @MainActor static func request(needsSpeech: Bool, _ done: @escaping (MicAccess) -> Void) {
        requestMic { granted in
            guard granted else { done(.denied); return }
            guard needsSpeech else { done(.granted); return }
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: done(.granted)
            case .denied, .restricted: done(.denied)
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { status in
                    Task { @MainActor in done(status == .authorized ? .granted : .denied) }
                }
            @unknown default: done(.denied)
            }
        }
    }

    private static func requestMic(_ cb: @escaping (Bool) -> Void) {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: cb(true)
        case .denied: cb(false)
        default: AVAudioApplication.requestRecordPermission { ok in Task { @MainActor in cb(ok) } }
        }
    }
}
