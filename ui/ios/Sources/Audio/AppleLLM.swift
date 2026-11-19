import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device text generation for the Rust core's Bridge — Apple Foundation Models
/// (iOS 26+, Apple-Intelligence hardware). Implements the UniFFI `OnDeviceLlm`
/// callback the core calls when generation is routed on-device. The FFI method is
/// synchronous, so we block on the async model call (always invoked off the main
/// thread by the engine's runtime).
final class AppleLLM: OnDeviceLlm {
    func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            // We expose the On-device lane whenever Foundation Models is compiled in on
            // iOS 26+ — i.e. the platform *can* run it — rather than gating on
            // `SystemLanguageModel.default.availability`. That live check reports
            // `.unavailable` for transient/over-conservative reasons (model still
            // warming after an OS update, Apple Intelligence toggled on but not yet
            // provisioned), which left the lane stuck off on capable devices. The real
            // failure, if Apple Intelligence is genuinely off, now surfaces at
            // `generate()` time. The lane is labelled "requires Apple Intelligence" in
            // settings. We still log the live status for diagnostics.
            let availability = SystemLanguageModel.default.availability
            Log.engine.info("Apple on-device LLM availability (live, advisory): \(String(describing: availability), privacy: .public)")
            return true
        }
        Log.engine.info("Apple on-device LLM: iOS < 26 at runtime")
        #else
        Log.engine.info("Apple on-device LLM: FoundationModels not compiled in")
        #endif
        return false
    }

    // `model` (the core's per-call engine hint) is moot here — this engine IS
    // Apple Foundation Models; routing between engines happens in BridgeLLM.
    func generate(system: String, user: String, model: String?) throws -> String {
        guard isAvailable() else { throw AppleLLMError.unavailable }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: Result<String, Error> = .failure(AppleLLMError.unavailable)
            Task {
                do {
                    let session = LanguageModelSession(model: .default, instructions: system)
                    let response = try await session.respond(to: user)
                    outcome = .success(response.content)
                } catch {
                    outcome = .failure(error)
                }
                semaphore.signal()
            }
            // Bound the wait: Foundation Models is normally fast, but a stuck respond()
            // would otherwise block the core's single triage worker forever (the FFI
            // call is synchronous). On timeout, fail soft so the worker moves on.
            if semaphore.wait(timeout: .now() + 90) == .timedOut {
                throw AppleLLMError.timedOut
            }
            return try outcome.get()
        }
        #endif
        throw AppleLLMError.unavailable
    }

    /// Classify a command into the Bridge intent schema using GUIDED GENERATION, so the
    /// output is guaranteed schema-valid (no JSON-parsing guesswork). Returns the core's
    /// intent JSON shape (`{"intent","confidence","slots","say"}`). Apple-Intelligence only.
    func generateIntent(system: String, user: String, model: String?) throws -> String {
        guard isAvailable() else { throw AppleLLMError.unavailable }
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            let semaphore = DispatchSemaphore(value: 0)
            var outcome: Result<String, Error> = .failure(AppleLLMError.unavailable)
            Task {
                do {
                    let session = LanguageModelSession(model: .default, instructions: system)
                    let response = try await session.respond(to: user, generating: IntentResult.self)
                    outcome = .success(response.content.toCoreJSON())
                } catch {
                    outcome = .failure(error)
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 30) == .timedOut {
                throw AppleLLMError.timedOut
            }
            return try outcome.get()
        }
        #endif
        throw AppleLLMError.unavailable
    }
}

enum AppleLLMError: Error { case unavailable, timedOut }

#if canImport(FoundationModels)
import FoundationModels

/// Guided-generation schema for the Bridge intent layer — mirrors the core intent
/// catalog in `core/src/bridge/intent.rs` (keep the intent keys + slot fields in sync).
/// Foundation Models guarantees the model fills exactly this shape; `toCoreJSON()` then
/// re-nests the flat slots into the `{intent, confidence, slots, say}` shape core parses.
@available(iOS 26, *)
@Generable
struct IntentResult {
    @Guide(description: "Exactly one intent key: agenda_today, needs_response, missed_last_week, meeting_detail, read_email, brief, mark_read, archive, trash, draft_reply, schedule_meeting, add_reminder, chat, or unknown.")
    var intent: String
    @Guide(description: "How confident you are, 0.0 to 1.0.")
    var confidence: Double
    @Guide(description: "A short clarifying question when intent is unknown or you're unsure; otherwise empty.")
    var say: String
    // Optional slots (fill only those relevant to the chosen intent).
    @Guide(description: "Which email: last_unread, latest, or current.")
    var target: String?
    @Guide(description: "Date as YYYY-MM-DD, resolved from the current time.")
    var date: String?
    var hour: Int?
    var minute: Int?
    var title: String?
    @Guide(description: "What the user wants to say in a drafted reply.")
    var instruction: String?
    var location: String?
    @Guide(description: "Meeting start, RFC3339, resolved from the current time.")
    var start: String?
    @Guide(description: "Meeting end, RFC3339.")
    var end: String?
    @Guide(description: "Names of meeting attendees.")
    var attendeeNames: [String]?

    /// Re-nest into the `{intent, confidence, slots, say}` JSON the core parser expects.
    func toCoreJSON() -> String {
        var slots: [String: Any] = [:]
        if let v = target, !v.isEmpty { slots["target"] = v }
        if let v = date, !v.isEmpty { slots["date"] = v }
        if let v = hour { slots["hour"] = v }
        if let v = minute { slots["minute"] = v }
        if let v = title, !v.isEmpty { slots["title"] = v }
        if let v = instruction, !v.isEmpty { slots["instruction"] = v }
        if let v = location, !v.isEmpty { slots["location"] = v }
        if let v = start, !v.isEmpty { slots["start"] = v }
        if let v = end, !v.isEmpty { slots["end"] = v }
        if let v = attendeeNames, !v.isEmpty { slots["attendee_names"] = v }
        let root: [String: Any] = [
            "intent": intent,
            "confidence": confidence,
            "say": say,
            "slots": slots,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"intent\":\"unknown\",\"confidence\":0,\"slots\":{},\"say\":\"\"}"
        }
        return json
    }
}
#endif
