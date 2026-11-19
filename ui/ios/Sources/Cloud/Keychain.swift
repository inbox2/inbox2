import Foundation
import Security
import SwiftUI

/// Minimal Keychain wrapper for the inbox2-domain session token + the personal API
/// key — the secrets the cloud (MX) client and the image proxy hold. (Channel
/// credentials live in the Rust engine's encrypted store; this is separate.) Items
/// are accessible after first unlock so a background refresh can use the token while
/// the device is locked, and are pinned `ThisDeviceOnly` so they never sync to iCloud
/// Keychain or migrate into an encrypted device backup.
enum Keychain {
    private static let service = "com.inbox2.cloud"

    /// Accessibility class for every stored secret. `AfterFirstUnlock` so a background
    /// refresh can read the session token while the device is locked; `ThisDeviceOnly`
    /// so secrets stay on this device (excluded from iCloud Keychain + backups).
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = accessibility
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.cloud.error("keychain set failed: \(status)") }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Server-side image proxy — the iOS counterpart to the desktop `useRemoteImages`
/// proxy path. Remote images in mail are fetched through the Rails backend so the
/// sender never sees the reader's IP, device, or open-time (tracking-pixel defence).
/// The bearer is the personal API key (`ink_…`) when set, else the signed-in inbox2
/// mx session token — the same dual-source model the desktop `image_proxy_controller`
/// accepts. Images come back as `data:` URIs so the WebView keeps a strict CSP.
enum ImageProxy {
    static let apiKeyPrefix = "ink_"

    /// The bearer to authenticate the proxy: the personal API key if present, else the
    /// MX session token. Nil when neither is available (images then stay blocked).
    static func bearer(apiKey: String?) -> String? {
        if let apiKey, !apiKey.isEmpty { return apiKey }
        return Keychain.get(CloudSession.tokenKey)
    }

    /// Whether a proxy bearer is available at all (drives the reader's image policy).
    static func hasBearer(apiKey: String?) -> Bool { bearer(apiKey: apiKey) != nil }

    /// Fetch a remote image server-side and return it as a base64 `data:` URI. A data
    /// URI keeps the reader's CSP at `data: blob:` (no `https:`), so nothing loads
    /// cross-origin even after the swap. Nil on any failure (missing bearer, non-2xx,
    /// non-image, transport) — the placeholder simply stays.
    static func fetchDataURI(_ rawURL: String, apiKey: String?) async -> String? {
        guard let token = bearer(apiKey: apiKey) else { return nil }
        guard let encoded = rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: AppConfig.apiBase + "/image-proxy?url=" + encoded) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.cloud.info("image-proxy \((resp as? HTTPURLResponse)?.statusCode ?? -1) for \(rawURL.prefix(80))")
                return nil
            }
            let ctHeader = http.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
            let ct = ctHeader.split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? "image/png"
            return "data:\(ct);base64,\(data.base64EncodedString())"
        } catch {
            Log.cloud.info("image-proxy failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Consented direct fetch — graceful degradation for hosts the proxy can't reach.
    /// Some image CDNs sit behind bot management (Cloudflare etc.) that 403s any
    /// server-side client by TLS fingerprint, while real devices pass. After an
    /// explicit "Load directly" tap, the failed image is fetched straight from the
    /// device — revealing the reader's IP to that host only — and returned as a
    /// `data:` URI so the WebView CSP stays strict (`data: blob:`, never `https:`).
    static func fetchDirectDataURI(_ rawURL: String) async -> String? {
        guard let url = URL(string: rawURL) ?? rawURL
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            .flatMap(URL.init(string:)) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Log.cloud.info("image-direct \((resp as? HTTPURLResponse)?.statusCode ?? -1) for \(rawURL.prefix(80))")
                return nil
            }
            let ctHeader = http.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
            let ct = ctHeader.split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? "image/png"
            guard ct.hasPrefix("image/") else { return nil }
            return "data:\(ct);base64,\(data.base64EncodedString())"
        } catch {
            Log.cloud.info("image-direct failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Privacy settings store: the personal API key (Keychain) + the "load remote images
/// privately" preference (UserDefaults). Injected app-wide; the reader reads it to
/// decide whether to route blocked images through `ImageProxy`. Mirrors the desktop
/// PrivacySettings panel + `inbox2ApiKey` pairing.
@MainActor
final class PrivacyStore: ObservableObject {
    // Shared with PushRegistrar, which resolves the same bearer for /push-devices.
    static let apiKeyAccount = "image_proxy_api_key"
    private static let proxyEnabledKey = "inbox2_image_proxy_enabled"
    private static let directConsentsKey = "inbox2_image_direct_consents"
    /// Cap the remembered set so it can't grow unbounded; keep the most recent N.
    private static let directConsentsCap = 1000

    /// The personal API key, or nil. Persisted in the Keychain (never UserDefaults).
    @Published private(set) var apiKey: String?
    /// Whether requested remote images load privately through the proxy. Default on.
    @Published var proxyEnabled: Bool {
        didSet { UserDefaults.standard.set(proxyEnabled, forKey: Self.proxyEnabledKey) }
    }

    /// Message keys the user consented to load remote images DIRECTLY for — the proxy
    /// couldn't fetch them (bot-managed CDNs 403 server-side clients) and the user tapped
    /// "Load directly". Persisted (ordered, capped) so revisiting the same email doesn't
    /// re-prompt. The web counterpart lives in shownMessages.js.
    private var directConsents: [String]

    init() {
        apiKey = Keychain.get(Self.apiKeyAccount)
        proxyEnabled = (UserDefaults.standard.object(forKey: Self.proxyEnabledKey) as? Bool) ?? true
        directConsents = (UserDefaults.standard.array(forKey: Self.directConsentsKey) as? [String]) ?? []
    }

    /// Whether the user already consented to load this message's images directly.
    func isDirectConsented(_ messageKey: String) -> Bool {
        directConsents.contains(messageKey)
    }

    /// Remember that the user consented to load this message's images directly.
    func setDirectConsented(_ messageKey: String) {
        guard !messageKey.isEmpty, !directConsents.contains(messageKey) else { return }
        directConsents.append(messageKey)
        if directConsents.count > Self.directConsentsCap {
            directConsents.removeFirst(directConsents.count - Self.directConsentsCap)
        }
        UserDefaults.standard.set(directConsents, forKey: Self.directConsentsKey)
    }

    /// Validate (must be an `ink_` key) + persist. Returns false if malformed.
    @discardableResult
    func saveApiKey(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.hasPrefix(ImageProxy.apiKeyPrefix) else { return false }
        Keychain.set(v, for: Self.apiKeyAccount)
        apiKey = v
        Log.cloud.info("saved image-proxy API key")
        return true
    }

    func clearApiKey() {
        Keychain.delete(Self.apiKeyAccount)
        apiKey = nil
        Log.cloud.info("cleared image-proxy API key")
    }
}
