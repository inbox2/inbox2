import CarPlay
import UIKit

/// Weak bridge from the SwiftUI app to the CarPlay scene. The scene delegate is created
/// by UIKit as a *separate* scene and can't read the SwiftUI environment, so — like
/// `PushRegistrar.engine` — the app hands it the shared instances via weak statics
/// (set from `Inbox2App`'s `.task`). Weak so the scene never keeps them alive.
enum CarPlayLink {
    @MainActor static weak var engine: EngineModel?
    @MainActor static weak var voice: VoiceEngineManager?
    @MainActor static weak var speaker: Speaker?
    @MainActor static weak var router: BridgeRouter?
}

/// The CarPlay scene: a list of the three Bridge briefs, spoken hands-free through the
/// SAME `Speaker`/`EngineModel`/`VoiceEngineManager` the phone app uses. Connecting flips
/// `voice.carPlayConnected`, which forces `effectiveCarMode` on (the full brief).
///
/// NOTE: CarPlay requires the Apple-managed `com.apple.developer.carplay-communication`
/// entitlement, granted on request. It is intentionally NOT in `Inbox2.entitlements`
/// (adding an ungranted entitlement breaks device code-signing). Until it's granted +
/// added, iOS never instantiates this scene — the phone app is unaffected. The scene
/// config in `project.yml` and this delegate are ready for that switch-on.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private let brain = BridgeBrain()
    /// The car's own spoken session. Speech goes through its `speak`, which arms the
    /// stop-word spotter before the voice starts, so "stop / cancel / ok" interrupts a
    /// brief in the car as it does on the phone (break-in is mandatory on every surface).
    @MainActor private lazy var session = BridgeSession()

    /// One Bridge action offered as a CarPlay list row.
    private enum Brief: String, CaseIterable {
        case daily = "Daily brief"
        case tomorrow = "Tomorrow"
        case week = "Weekly highlights"

        var detail: String {
            switch self {
            case .daily: return "Your inbox at a glance"
            case .tomorrow: return "Tomorrow's calendar"
            case .week: return "Highlights of the week"
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Task { @MainActor in CarPlayLink.voice?.carPlayConnected = true }
        interfaceController.setRootTemplate(makeRootTemplate(), animated: true, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        Task { @MainActor in CarPlayLink.voice?.carPlayConnected = false }
    }

    // MARK: - Templates

    private func makeRootTemplate() -> CPListTemplate {
        let items: [CPListItem] = Brief.allCases.map { brief in
            let item = CPListItem(text: brief.rawValue, detailText: brief.detail)
            item.handler = { [weak self] _, completion in
                self?.run(brief)
                completion()
            }
            return item
        }
        return CPListTemplate(title: "Bridge", sections: [CPListSection(items: items)])
    }

    // MARK: - Actions

    /// Generate the chosen brief and speak it through the shared Speaker. CarPlay is a
    /// driving context, so it always speaks the FULL brief (effectiveCarMode is forced on
    /// while connected). The spoken text is also shown on a confirmation template.
    private func run(_ brief: Brief) {
        Task { @MainActor in
            guard let engine = CarPlayLink.engine,
                  let voice = CarPlayLink.voice,
                  let speaker = CarPlayLink.speaker,
                  let router = CarPlayLink.router else { return }
            session.bind(engine: engine, voice: voice, speaker: speaker, router: router)

            speaker.stop()
            let reply: BridgeBrain.BridgeReply
            switch brief {
            case .daily:
                reply = await brain.briefSpoken(engine: engine, manager: voice, weather: await WeatherService.morningLine())
            case .tomorrow:
                reply = await brain.tomorrowSpoken(engine: engine, manager: voice)
            case .week:
                reply = await brain.weekHighlightsSpoken(engine: engine, manager: voice)
            }

            switch reply {
            case .ok(let text):
                session.speak(text)
                present(title: brief.rawValue, body: text)
            case .openAIError(let err):
                present(title: brief.rawValue, body: "OpenAI error: \(err)")
            case .notReady:
                present(title: brief.rawValue, body: "Still starting up. Try again in a moment.")
            }
        }
    }

    /// Show the spoken text on a CarPlay information template (pop any previous one first
    /// so confirmations don't stack).
    @MainActor private func present(title: String, body: String) {
        guard let interfaceController else { return }
        let info = CPInformationTemplate(
            title: title,
            layout: .leading,
            items: [CPInformationItem(title: nil, detail: body)],
            actions: []
        )
        if interfaceController.templates.count > 1 {
            interfaceController.popToRootTemplate(animated: false, completion: nil)
        }
        interfaceController.pushTemplate(info, animated: true, completion: nil)
    }
}
