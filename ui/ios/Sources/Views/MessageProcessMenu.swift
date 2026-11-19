import SwiftUI

/// The reader's "Process with" submenu (inside "Speak with"): re-run this thread's
/// summaries through a chosen engine (the label + priority come from Jev when a key
/// is set, whichever engine is picked) — Apple Intelligence (capable
/// hardware), each downloaded free variant (Gemma / Qwen), or OpenAI (saved key).
/// The result is written to the store with its `triage_source` tag. Split out of
/// `MessageView`; the reader keeps `reprocessing`/`reprocessError` (both also drive
/// the processing hairline + failure alert) via bindings and refreshes its
/// summaries indicator through `onReprocessed`.
struct MessageProcessMenu: View {
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var voice: VoiceEngineManager
    let convo: Conversation
    @Binding var reprocessing: Bool
    @Binding var reprocessError: String?
    let onReprocessed: () -> Void

    /// One engine the user can force this thread's summaries through.
    private struct ProcessOption: Identifiable {
        let id: String
        let name: String
        let icon: String
        let config: FfiBridgeConfig
    }

    /// The engines available right now: Apple Intelligence (capable hardware),
    /// each downloaded free variant (Gemma / Qwen), and OpenAI (saved key).
    private var processOptions: [ProcessOption] {
        var opts: [ProcessOption] = []
        let onDevice = { (model: String) in
            FfiBridgeConfig(generation: "apple", openaiKey: nil, model: nil, onDeviceModel: model,
                            concise: false, weather: nil)
        }
        let lanes = engine.modelLanes("nlu", hasKey: voice.canUseOpenAI)
        if lanes.contains(where: { $0.lane == BridgeLane.native.rawValue && $0.available }) {
            opts.append(.init(id: BridgeModelIDs.appleFM, name: "Apple Intelligence",
                              icon: "sparkles", config: onDevice(BridgeModelIDs.appleFM)))
        }
        for id in [BridgeModelIDs.gemma, BridgeModelIDs.qwen] where engine.modelPath(id) != nil {
            opts.append(.init(id: id, name: id == BridgeModelIDs.gemma ? "Gemma" : "Qwen",
                              icon: "cpu", config: onDevice(id)))
        }
        if voice.canUseOpenAI {
            opts.append(.init(id: "openai", name: "OpenAI", icon: "cloud",
                              config: FfiBridgeConfig(generation: "openai", openaiKey: voice.openAIKey,
                                                      model: nil, onDeviceModel: nil,
                                                      concise: false, weather: nil)))
        }
        return opts
    }

    /// Re-run this thread's label + summaries through a specific engine — the
    /// evaluation hook behind the model-provenance tracking. The result is written
    /// to the store with its `triage_source` tag and refreshes this reader in place.
    var body: some View {
        let options = processOptions
        // Domain threads are summarized server-side; nothing to force locally.
        if !convo.isDomain && !options.isEmpty {
            Divider()
            Menu {
                ForEach(options) { opt in
                    Button { reprocess(with: opt) } label: { Label(opt.name, systemImage: opt.icon) }
                }
            } label: {
                Label("Process with", systemImage: "brain")
            }
            .disabled(reprocessing)
        }
    }

    private func reprocess(with opt: ProcessOption) {
        guard !reprocessing else { return }
        Log.action.info("process-with \(opt.id, privacy: .public) on \(convo.id, privacy: .public)")
        withAnimation(.easeInOut(duration: 0.3)) { reprocessing = true }
        Task {
            let result = await engine.reprocessConversation(opt.config, conversationKey: convo.id)
            await MainActor.run {
                switch result {
                case .success(let source):
                    Log.action.info("process-with wrote source=\(source, privacy: .public)")
                case .failure(FfiError.Engine(let msg)):
                    Log.action.error("process-with \(opt.id, privacy: .public) failed: \(msg, privacy: .public)")
                    reprocessError = msg
                }
                withAnimation(.easeInOut(duration: 0.3)) { reprocessing = false }
                onReprocessed()
            }
        }
    }
}
