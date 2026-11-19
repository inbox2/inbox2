import Foundation

/// Thin coordinator over the shared Rust Bridge. All prompt/brief/OpenAI/agent logic
/// lives in the core now (`core/src/bridge`); this just builds the engine config from
/// the user's voice settings and maps the FFI reply for the UI.
@MainActor
final class BridgeBrain {
    enum BridgeReply {
        case ok(String)
        case openAIError(String)
        /// The core didn't answer (still booting / transient) — show a loading status
        /// rather than speaking an error.
        case notReady
    }

    /// The spoken daily brief. `weather` (when given, mornings only) is appended by the
    /// core to the end of the brief. Verbosity follows the car-mode toggle: normal mode
    /// speaks a terse headline, car mode speaks the full rundown.
    func briefSpoken(engine: EngineModel, manager: VoiceEngineManager, weather: String? = nil) async -> BridgeReply {
        let config = manager.bridgeConfig(engine: engine, concise: !manager.effectiveCarMode, weather: weather)
        return map(await engine.bridgeBrief(config))
    }

    /// Tomorrow's spoken calendar preview.
    func tomorrowSpoken(engine: EngineModel, manager: VoiceEngineManager) async -> BridgeReply {
        map(await engine.bridgeTomorrow(config(manager, engine)))
    }

    /// The conversational "highlights of the week" rundown.
    func weekHighlightsSpoken(engine: EngineModel, manager: VoiceEngineManager) async -> BridgeReply {
        map(await engine.bridgeWeekHighlights(config(manager, engine)))
    }

    /// Conversational reply to a voice command.
    func respond(transcript: String, engine: EngineModel, manager: VoiceEngineManager) async -> BridgeReply {
        map(await engine.bridgeReply(config(manager, engine), transcript: transcript))
    }

    /// Interpret a voice command into a confidence-scored action (speak / clarify /
    /// draft email / draft meeting). Returns nil if the core isn't ready yet.
    func command(transcript: String, engine: EngineModel, manager: VoiceEngineManager) async -> FfiBridgeAction? {
        await engine.bridgeCommand(config(manager, engine), transcript: transcript)
    }

    /// Spoken read-out of a single email thread (for the email-detail audio button).
    func emailVoice(conversationKey: String, engine: EngineModel, manager: VoiceEngineManager) async -> BridgeReply {
        map(await engine.bridgeEmailVoice(config(manager, engine), conversationKey: conversationKey))
    }

    private func config(_ v: VoiceEngineManager, _ engine: EngineModel) -> FfiBridgeConfig {
        // Single source for the NLU lane — shared with the background triage
        // worker via EngineModel.setAiConfig (see VoiceEngineManager.bridgeConfig).
        v.bridgeConfig(engine: engine)
    }

    private func map(_ reply: FfiBridgeReply?) -> BridgeReply {
        guard let reply else { return .notReady }
        if let err = reply.openaiError, !err.isEmpty { return .openAIError(err) }
        return .ok(reply.text)
    }
}
