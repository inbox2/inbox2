import Foundation
import CryptoKit
import UIKit

/// Errors from the "link this device to your inbox2 account" flow.
enum DeviceLinkError: LocalizedError {
    case server(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .badResponse: return "Something went wrong. Try again."
        }
    }
}

/// OAuth-style "link this device to your inbox2 account" flow — the native
/// counterpart of the web approval page. Mirrors `OAuthService`'s loopback + PKCE
/// machinery (and reuses its `LoopbackServer`): the approval page is opened in the
/// system browser, where the signed-in user approves; the page redirects to a
/// `127.0.0.1` loopback the app is listening on, carrying a one-time `code`; the app
/// exchanges that code (+ the PKCE verifier that never left the device) for an `ink_`
/// account token at `/auth/device-link/token`.
///
/// The minted token IS the account bearer — `CloudSession.adoptLinkedToken` stores it
/// and validates it like a password login, so approving on the web signs the app in.
@MainActor
final class DeviceLinkService {
    /// UserDefaults key for a manual approval-page override (full URL), honored only
    /// in DEBUG builds — same posture as `AppConfig.baseURLKey` for the API base.
    static let linkURLKey = "inbox2_device_link_url"

    /// The hosted production approval page (Cloudflare Pages, `mail.inbox2.com`).
    static let defaultLinkURL = "https://mail.inbox2.com/link"

    /// The API base (the token exchange endpoint) — shared with the rest of the app.
    static var apiBase: String { AppConfig.apiBase }

    /// The callback path on the loopback redirect (`http://127.0.0.1:<port>/cb`).
    private static let callbackPath = "/cb"

    /// Overall budget for the user to approve in the browser before we give up.
    private static let approvalTimeout: TimeInterval = 180

    /// The approval-page URL in effect: a *valid* DEBUG override if set, else the prod
    /// default. The override must be a well-formed `https://` URL (or loopback `http`)
    /// so a stray default can't redirect the approval flow to an arbitrary host.
    static var linkURL: String {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: linkURLKey),
           let override = AppConfig.sanitizedOverride(raw) {
            return override
        }
        #endif
        return defaultLinkURL
    }

    /// Run the full device-link flow: bind a loopback listener, hand the approval URL
    /// to `present` (shown in SFSafariViewController), wait for the `127.0.0.1`
    /// redirect, verify `state`, and exchange the code for the `ink_` token. Throws on
    /// cancellation, timeout, or any failure — all non-fatal to the app.
    func link(deviceName: String? = nil, present: (URL) -> Void) async throws -> String {
        let server = try LoopbackServer()
        let port = await server.start()
        let state = Self.randomURLSafeToken()
        let pkce = DeviceLinkPKCE()
        let redirect = "http://127.0.0.1:\(port)\(Self.callbackPath)"
        let name = deviceName ?? UIDevice.current.name

        // Cancelling the surrounding Task (the user dismisses the sheet) tears down the
        // listener, which unblocks `awaitCallback`.
        return try await withTaskCancellationHandler {
            // Time-box the approval: when it lapses, cancel the listener so the waiting
            // `awaitCallback` throws rather than hanging forever.
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.approvalTimeout * 1_000_000_000))
                server.cancel()
            }
            defer { timeoutTask.cancel() }
            do {
                let url = try Self.approvalURL(deviceName: name, redirect: redirect,
                                               state: state, challenge: pkce.challenge)
                present(url)
                let (code, returnedState) = try await server.awaitCallback()
                guard returnedState == state else { throw DeviceLinkError.server("State mismatch.") }
                return try await Self.exchange(code: code, verifier: pkce.verifier, redirect: redirect)
            } catch {
                server.cancel()
                throw error
            }
        } onCancel: {
            server.cancel()
        }
    }

    /// Build the browser approval URL:
    /// `{linkURL}?device_name=…&platform=ios&redirect_uri=…&state=…&code_challenge=…&code_challenge_method=S256`
    private static func approvalURL(deviceName: String, redirect: String, state: String, challenge: String) throws -> URL {
        guard var comps = URLComponents(string: linkURL) else {
            throw DeviceLinkError.server("Bad link URL.")
        }
        comps.queryItems = [
            .init(name: "device_name", value: deviceName),
            .init(name: "platform", value: "ios"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = comps.url else { throw DeviceLinkError.server("Couldn't build the link URL.") }
        Log.cloud.info("device-link: opening approval page")
        return url
    }

    /// POST the code (+ PKCE verifier) to mint the account token. No auth header —
    /// the code itself is the credential. Returns the `ink_` token from the 201 body.
    private static func exchange(code: String, verifier: String, redirect: String) async throws -> String {
        guard let url = URL(string: "\(apiBase)/auth/device-link/token") else {
            throw DeviceLinkError.server("Bad API base.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
        ])
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw DeviceLinkError.server(error.localizedDescription) }

        guard let http = resp as? HTTPURLResponse else { throw DeviceLinkError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = errorMessage(from: data)
            throw DeviceLinkError.server(msg.isEmpty ? "Linking failed (\(http.statusCode))." : msg)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty else {
            throw DeviceLinkError.badResponse
        }
        Log.cloud.info("device-link: minted account token")
        return token
    }

    /// Pull a human message out of the API's `ErrorSerializer` shape (`{errors:[{message}]}`).
    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let errs = obj["errors"] as? [[String: Any]], let m = errs.first?["message"] as? String { return m }
        if let m = obj["error"] as? String { return m }
        return ""
    }

    /// A random url-safe `state` (16 bytes of CSPRNG entropy, base64url, no padding).
    private static func randomURLSafeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).deviceLinkBase64URL()
    }
}

/// A PKCE (RFC 7636, S256) pair for the device-link flow. The `verifier` is 64 bytes
/// of CSPRNG entropy, base64url-encoded (no padding); the `challenge` is its SHA-256,
/// base64url-encoded. The verifier is sent only on the token exchange — so a code
/// lifted off the loopback redirect is useless without it.
struct DeviceLinkPKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).deviceLinkBase64URL()
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).deviceLinkBase64URL()
    }
}

private extension Data {
    /// Base64url (RFC 4648 §5), no `=` padding. Named to avoid clashing with the
    /// file-private helper in `OAuthService.swift`.
    func deviceLinkBase64URL() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
