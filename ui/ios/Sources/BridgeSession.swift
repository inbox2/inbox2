import AVFoundation
import SwiftUI

/// The Bridge's spoken session, lifted out of `BridgeView` so a second surface (the
/// CarPlay delegate, later) can drive the same flow: briefs, the command → intent
/// dispatch, barge-in, mic access and the status line. The view binds the shared
/// collaborators once (`bind`, on appear) and renders what this publishes.
///
/// `speak(_:)` is THE entry point for Bridge speech: it arms the stop-word spotter
/// before the voice starts (mic-before-voice), so every surface gets break-in for
/// free. The Bridge never sends — commands only ever hand back drafts via the router.
@MainActor
final class BridgeSession: ObservableObject {
    /// Stop-word break-in — armed whenever the Bridge speaks (briefs included), so
    /// "ok / stop / cancel" interrupts without reaching for the orb.
    let bargeIn = KeywordSpotter()
    private let brain = BridgeBrain()

    /// True while a tool-using command dialog is open (the agent may ask a follow-up,
    /// and a spoken "cancel" abandons it). Cleared on a fresh brief.
    @Published private(set) var dialogActive = false
    @Published private(set) var isGenerating = false
    /// True while we're waiting on the core to finish booting before a brief can run —
    /// drives a "starting the engine" status under the button.
    @Published private(set) var engineLoading = false
    /// A short-lived status line (e.g. "still starting up") shown under the button.
    @Published private(set) var transientStatus: String?
    /// Microphone / speech access — drives the small inline badge near the orb when the
    /// mic is denied or unavailable. Optimistic (`granted`, no badge) until an action
    /// (playing a summary or holding the orb) resolves the real state.
    @Published private(set) var micAccess: MicAccess = .granted
    /// Follow-up links under the brief — "Check tomorrow" and "Highlights of the week"
    /// surface together once the daily brief starts speaking, and fade after a minute
    /// (the timer resets each time one is tapped).
    @Published private(set) var showFollowUps = false

    /// The in-flight command task, so a barge-in "cancel/stop" can abort it.
    private var commandTask: Task<Void, Never>?
    private var statusFlashTask: Task<Void, Never>?
    private var followUpsHideTask: Task<Void, Never>?

    // Bound once by the owning view (`bind`, on appear) before any call; app-lifetime objects.
    private var engine: EngineModel!
    private var voice: VoiceEngineManager!
    private var speaker: Speaker!
    private var router: BridgeRouter!

    init() {
        // A spoken "cancel/stop/ok" while the agent talks interrupts it.
        bargeIn.onKeyword = { [weak self] word in self?.handleBargeIn(word) }
    }

    func bind(engine: EngineModel, voice: VoiceEngineManager, speaker: Speaker, router: BridgeRouter) {
        self.engine = engine; self.voice = voice; self.speaker = speaker; self.router = router
    }

    /// True while a brief is being composed or a voice is being prepared — taps are
    /// ignored in this window so a double-tap can't spawn two overlapping briefs.
    // `speaker` is bound on appear; a sheet can render the body first (Lore's orb opens
    // the Bridge as a sheet), so read it optionally rather than trap on nil.
    var isBusy: Bool { isGenerating || (speaker?.isPreparing ?? false) || engineLoading }

    // MARK: - Speaking

    /// Speak `text` with barge-in armed first. All Bridge speech — briefs included —
    /// opens a `.playAndRecord` session so "cancel/stop/ok" is heard over the voice.
    func speak(_ text: String) {
        armDialog()
        speaker.speak(text, using: voice, engine: engine)
    }

    /// Speak a reply, or surface an OpenAI failure via the system voice with guidance.
    func speak(_ reply: BridgeBrain.BridgeReply) {
        switch reply {
        case .ok(let text):
            speak(text)
        case .openAIError(let msg):
            armDialog()
            speaker.speakSystem("OpenAI returned the error: \(msg). Go into settings and update or disable your key.")
        case .notReady:
            flashStatus("Still starting up. Give it a moment.")
        }
    }

    /// Mic-before-voice: bring the `.playAndRecord` session and the barge-in spotter's
    /// voice-processing engine up BEFORE speech renders — arming them after playback has
    /// begun rebuilds the audio graph mid-utterance and swallows the first ~second.
    private func armDialog() {
        speaker.prepareDialogSession()
        // Kokoro plays through the spotter's voice-processing engine (full level +
        // AEC reference) instead of alongside it as attenuated "other audio".
        speaker.dialogPlaybackEngine = { [weak bargeIn] in bargeIn?.playbackEngine }
        // Request mic access so "cancel/stop/ok" break-in works over the summary — and so a
        // denial/unavailability surfaces as a badge. The summary still speaks regardless;
        // only the barge-in spotter needs the mic, so it starts only once access is granted.
        ensureMicAccess(needsSpeech: true) { [weak self] access in
            if access == .granted { self?.bargeIn.start() }
        }
    }

    /// Resolve mic (+ on-device speech) access, updating `micAccess` for the badge, then
    /// hand the result to `then`. Never blocks speech — the callback runs after the system
    /// prompt resolves on first use, and returns immediately once access is determined.
    private func ensureMicAccess(needsSpeech: Bool, _ then: @escaping (MicAccess) -> Void) {
        if needsSpeech && !MicPermission.recognizerAvailable() {
            setMicAccess(.unavailable)
            then(.unavailable)
            return
        }
        MicPermission.request(needsSpeech: needsSpeech) { [weak self] access in
            self?.setMicAccess(access)
            then(access)
        }
    }

    func setMicAccess(_ access: MicAccess) {
        withAnimation(.easeInOut(duration: 0.25)) { micAccess = access }
    }

    /// Clear a stale denial badge if the user has since enabled access in Settings.
    func refreshMicAccess() {
        if AVAudioApplication.shared.recordPermission == .granted { micAccess = .granted }
    }

    // MARK: - Briefs

    func speakBrief() {
        run { [brain, engine, voice] in
            // Mornings get a short weather line appended by the core; fetched here so a
            // failure (offline, no API) simply omits it. Non-mornings skip the call.
            let weather = await WeatherService.morningLine()
            return await brain.briefSpoken(engine: engine!, manager: voice!, weather: weather)
        }
    }
    func speakTomorrow() { run { [brain, engine, voice] in await brain.tomorrowSpoken(engine: engine!, manager: voice!) } }
    func speakWeek() { run { [brain, engine, voice] in await brain.weekHighlightsSpoken(engine: engine!, manager: voice!) } }

    /// Generate a brief (interrupting whatever's playing), speak it, and reveal the
    /// follow-ups. If the core isn't ready yet, show a "starting the engine" status and
    /// retry once after a beat rather than speaking an error — covers the cold-launch
    /// window before the engine has finished booting.
    private func run(_ produce: @escaping () async -> BridgeBrain.BridgeReply) {
        guard !isBusy else { return }
        speaker.stop()
        // A brief/preview is a fresh interaction — drop any open command dialog so a
        // later "archive it" can't bind to a conversation from before.
        bargeIn.stop()
        commandTask?.cancel()
        engine.bridgeResetDialog()
        dialogActive = false
        transientStatus = nil
        isGenerating = true
        Task {
            var reply = await produce()
            if case .notReady = reply {
                isGenerating = false
                withAnimation(.easeInOut(duration: 0.2)) { engineLoading = true }
                try? await Task.sleep(for: .seconds(1.5))
                isGenerating = true
                reply = await produce()
                withAnimation(.easeInOut(duration: 0.2)) { engineLoading = false }
            }
            isGenerating = false
            speak(reply)
            if case .notReady = reply {} else { revealFollowUps() }
        }
    }

    // MARK: - Commands (voice → intent)

    /// A finished voice transcript → the intent layer: it answers queries by speaking,
    /// runs reversible inbox actions, or hands back a DRAFT (reply / meeting) that we put
    /// on screen for review. It never sends or saves.
    func handleCommand(_ transcript: String) {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never go silent: if nothing was heard, say so instead of doing nothing.
        guard !t.isEmpty else {
            speak("I didn't catch that. Hold the orb and try again.")
            return
        }
        dialogActive = true
        commandTask?.cancel()
        // Lane diagnostics: STT/NLU/TTS are independent per-capability lanes. Log the
        // resolved set so "the orb isn't on the right lane" is observable on device —
        // nluGeneration is what the brain actually runs (openai only when nlu=openai AND
        // a key is present; otherwise on-device Apple/Qwen).
        let cfg = voice.bridgeConfig(engine: engine)
        Log.engine.info("orb lanes — stt=\(self.voice.pref(.stt).rawValue, privacy: .public) nlu=\(self.voice.pref(.nlu).rawValue, privacy: .public) tts=\(self.voice.pref(.tts).rawValue, privacy: .public) hasKey=\(self.voice.hasKey, privacy: .public) → nluGeneration=\(cfg.generation, privacy: .public) onDeviceModel=\(cfg.onDeviceModel ?? "-", privacy: .public)")
        // Show the working indicator so a slower turn (e.g. an on-device model) reads as
        // "thinking", not "no response".
        isGenerating = true
        commandTask = Task {
            let action = await brain.command(transcript: t, engine: engine, manager: voice)
            isGenerating = false
            guard !Task.isCancelled else { return }
            await route(action)
        }
    }

    /// Act on a command result: speak an answer/clarification, or open a draft sheet.
    private func route(_ action: FfiBridgeAction?) async {
        guard let action else {
            flashStatus("Still starting up. Give it a moment.")
            return
        }
        if let err = action.openaiError, !err.isEmpty {
            armDialog()
            speaker.speakSystem("OpenAI returned the error: \(err). Go into settings and update or disable your key.")
            return
        }
        switch action.kind {
        case "draft_email":
            if let p = decodePayload(action.payloadJson) {
                router.pendingCompose = ComposeDraft(
                    fromAccountKey: p["accountKey"] as? String,
                    to: p["to"] as? String ?? "",
                    subject: p["subject"] as? String ?? "",
                    body: p["body"] as? String ?? ""
                )
            }
            speakResult(action.spoken)
        case "draft_event":
            if let p = decodePayload(action.payloadJson) {
                router.pendingEvent = await eventSeed(from: p)
            }
            speakResult(action.spoken)
        default: // "speak" / "clarify"
            speakResult(action.spoken)
        }
    }

    /// Speak a command result (in a `.playAndRecord` session so barge-in can interrupt).
    private func speakResult(_ text: String) {
        guard !text.isEmpty else { return }
        speak(text)
    }

    private func decodePayload(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Build an event seed from a draft_event payload, resolving attendee NAMES to email
    /// addresses from the user's contacts (recent correspondents); unresolved names are
    /// kept verbatim so the user can fix them on screen.
    private func eventSeed(from p: [String: Any]) async -> EventDraftSeed {
        let start = isoDate(p["startISO"] as? String) ?? Date().addingTimeInterval(3600)
        let end = isoDate(p["endISO"] as? String) ?? start.addingTimeInterval(1800)
        let names = p["attendeeNames"] as? [String] ?? []
        return EventDraftSeed(
            title: p["title"] as? String ?? "Meeting",
            start: start,
            end: end,
            location: p["location"] as? String ?? "",
            attendees: await resolveAttendees(names)
        )
    }

    private func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// Fuzzy-match spoken attendee names to known contacts (by name/email), falling back
    /// to the raw name when there's no match. `contacts()` already comes back ranked by
    /// recency-weighted frequency, so the first match is the one you actually mail.
    private func resolveAttendees(_ names: [String]) async -> [String] {
        guard !names.isEmpty else { return [] }
        let contacts = await engine.store.read { $0.contacts() }
        return names.map { name in
            let lower = name.lowercased()
            let best = contacts
                .first { $0.name.lowercased().contains(lower) || $0.email.lowercased().contains(lower) }
            return best?.email ?? name
        }
    }

    /// A barge-in stop-word landed while the agent was talking. Always halt speech and
    /// the in-flight turn; "cancel" additionally abandons the dialog.
    private func handleBargeIn(_ word: String) {
        bargeIn.stop()
        speaker.stop()
        commandTask?.cancel()
        isGenerating = false
        if word == "cancel" {
            engine.bridgeResetDialog()
            dialogActive = false
        }
        flashStatus("Okay, stopped.")
    }

    /// Leaving the Bridge: drop the spotter, the in-flight turn and the UI timers.
    func suspend() {
        followUpsHideTask?.cancel()
        statusFlashTask?.cancel()
        bargeIn.stop()
        commandTask?.cancel()
    }

    // MARK: - Status line + follow-ups

    /// Show a short-lived status line under the button, then clear it.
    func flashStatus(_ text: String) {
        statusFlashTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { transientStatus = text }
        statusFlashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { transientStatus = nil }
        }
    }

    /// Show both follow-up links and fade them out after a minute. Called after each
    /// brief so the timer resets while the user is engaging with them.
    func revealFollowUps() {
        followUpsHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { showFollowUps = true }
        followUpsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) { showFollowUps = false }
        }
    }
}
