import Foundation
import FoundationModels

func writeJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    if let data = try? encoder.encode(value),
        let str = String(data: data, encoding: .utf8) {
        print(str)
        fflush(stdout)
    }
}

struct CheckResponse: Codable {
    let available: Bool
    let reason: String?
}

struct Request: Codable {
    let cmd: String
    let system: String?
    let prompt: String?
    let email: String?
    let sender: String?
    let text: String?
    let max_tokens: Int?
}

struct GenerateResponse: Codable {
    let text: String?
    let error: String?
}

struct SmartRepliesResponse: Codable {
    let replies: [String]?
    let error: String?
}

struct SummarizeResponse: Codable {
    let summary: String?
    let error: String?
}

func main() async {
    let model = SystemLanguageModel.default
    let avail = model.availability
    let decoder = JSONDecoder()

    while let line = readLine() {
        guard let data = line.data(using: .utf8),
            let request = try? decoder.decode(Request.self, from: data) else {
            writeJSON(GenerateResponse(text: nil, error: "Invalid JSON input"))
            continue
        }

        switch request.cmd {
        case "check":
            switch avail {
            case .available:
                writeJSON(CheckResponse(available: true, reason: nil))
            case .unavailable(let reason):
                writeJSON(CheckResponse(available: false, reason: "unavailable: \(reason)"))
            @unknown default:
                writeJSON(CheckResponse(available: false, reason: "unknown"))
            }

        case "generate":
            let system = request.system ?? "You are a helpful email assistant."
            let prompt = request.prompt ?? ""
            do {
                let session = LanguageModelSession(model: .default, instructions: system)
                let response = try await session.respond(to: prompt)
                writeJSON(GenerateResponse(text: response.content, error: nil))
            } catch {
                writeJSON(GenerateResponse(text: nil, error: error.localizedDescription))
            }

        case "smart_replies":
            let system = "You are an email assistant. Generate exactly 3 short reply suggestions. Each reply 1-2 sentences, different tones. Return ONLY a JSON array of 3 strings."
            let prompt = "From: \(request.sender ?? "Unknown")\n\n\(request.email ?? "")"
            do {
                let session = LanguageModelSession(model: .default, instructions: system)
                let response = try await session.respond(to: prompt)
                let text = response.content
                if let data = text.data(using: .utf8),
                    let replies = try? JSONDecoder().decode([String].self, from: data) {
                    writeJSON(SmartRepliesResponse(replies: Array(replies.prefix(3)), error: nil))
                } else {
                    writeJSON(SmartRepliesResponse(replies: nil, error: "Failed to parse replies"))
                }
            } catch {
                writeJSON(SmartRepliesResponse(replies: nil, error: error.localizedDescription))
            }

        case "summarize":
            let system = "Summarize the following email thread in 2-3 concise bullet points. Focus on key decisions, action items, and deadlines."
            do {
                let session = LanguageModelSession(model: .default, instructions: system)
                let response = try await session.respond(to: request.text ?? "")
                writeJSON(SummarizeResponse(summary: response.content, error: nil))
            } catch {
                writeJSON(SummarizeResponse(summary: nil, error: error.localizedDescription))
            }

        default:
            writeJSON(GenerateResponse(text: nil, error: "Unknown command"))
        }
    }
}

await main()
