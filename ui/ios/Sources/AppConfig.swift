import Foundation

/// Single source of truth for the inbox2-domain (MX) API base URL.
///
/// The default is the hosted test deployment, reachable from anywhere (simulator,
/// device, cellular) — no Tailscale hop or local Rails required, and cloud push
/// works because the provider webhooks point at the same host. To develop against
/// a local Rails instead, set the `inbox2_cloud_api_base` UserDefault override
/// (full URL incl. `/api/v1`) — e.g. `http://localhost:4000/api/v1` on the
/// simulator, or the Mac's Tailscale name on a device.
enum AppConfig {
    /// UserDefaults key for a manual API-base override (full URL incl. `/api/v1`).
    static let baseURLKey = "inbox2_cloud_api_base"

    /// The hosted production environment (Rancher `inbox2-prod`, see docs/Deployment.md).
    private static let hostedBase = "https://api.inbox2.com/api/v1"

    /// Compiled-in default for the current build target.
    static var defaultBase: String { hostedBase }

    /// The API base in effect: a *valid* UserDefaults override if set, else the build
    /// default. The override is honored only in DEBUG builds and only when it is a
    /// well-formed `https://` URL (or plain-`http://` loopback for the simulator) —
    /// so a stray/hostile default can't silently redirect authenticated, bearer-
    /// carrying traffic to an arbitrary host or downgrade it to cleartext.
    static var apiBase: String {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: baseURLKey),
           let override = sanitizedOverride(raw) {
            return override
        }
        #endif
        return defaultBase
    }

    /// Validate an override URL: must parse, must have a host, and must be `https`
    /// unless it points at loopback (`localhost`/`127.0.0.1`), where dev `http` is
    /// allowed. Returns the trimmed URL on success, nil to fall back to the default.
    static func sanitizedOverride(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host, !host.isEmpty else { return nil }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        switch scheme {
        case "https": return trimmed
        case "http" where isLoopback: return trimmed
        default: return nil
        }
    }
}
