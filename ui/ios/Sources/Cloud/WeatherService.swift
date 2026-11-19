import Foundation

/// Fetches the short, ready-to-speak weather line for the Bridge morning brief from the
/// inbox2 API (`GET /weather`, IP-based, unauthenticated). Fully best-effort: any
/// failure — offline, slow, non-morning — yields `nil` and the brief simply omits the
/// line. Only called in the morning, so the network hit costs nothing the rest of the day.
enum WeatherService {
    private struct Response: Decodable { let short: String? }

    /// The weather line to append to a brief, or `nil` outside the morning window or on
    /// any failure. "Morning" matches the core's brief window (local hour < 12).
    static func morningLine() async -> String? {
        guard Calendar.current.component(.hour, from: Date()) < 12 else { return nil }
        return await fetch()
    }

    private static func fetch() async -> String? {
        guard let url = URL(string: "\(AppConfig.apiBase)/weather") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let short = decoded.short, !short.isEmpty else { return nil }
            return short
        } catch {
            Log.engine.info("weather fetch failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
