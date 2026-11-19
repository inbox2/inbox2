import Foundation
import Network
import CryptoKit

/// The two OAuth mail providers. `providerType` is what the engine's `add_account`
/// expects; `apiSegment` is the Rails proxy path.
enum OAuthProvider: String, CaseIterable, Identifiable {
    case google, microsoft
    var id: String { rawValue }
    var displayName: String { self == .google ? "Google" : "Microsoft" }
    var providerType: String { self == .google ? "gmail" : "microsoft" }
    var apiSegment: String { rawValue }
    var logoAsset: String { self == .google ? "ch-gmail" : "ch-microsoft" }
}

/// Tokens + identity obtained from a completed OAuth flow.
struct ConnectedTokens {
    let email: String
    let accessToken: String
    let refreshToken: String?
}

enum OAuthError: LocalizedError {
    case server(String)
    case cancelled
    case noEmail
    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .cancelled: return "Sign-in was cancelled."
        case .noEmail: return "Couldn't read the account email."
        }
    }
}

/// On-device OAuth via the Rails proxy (the proxy holds the client secret). Uses
/// the desktop's loopback-redirect pattern — the only redirect the proxy allows —
/// so it works with the existing Google/Microsoft OAuth client without any console
/// changes. The consent page is shown in SFSafariViewController (Google blocks
/// embedded WebViews); a local listener catches the 127.0.0.1 redirect.
@MainActor
final class OAuthService {
    private var server: LoopbackServer?

    /// The browser closed (Done/swipe, or SwiftUI dropped the sheet). Before the
    /// redirect this unblocks `connect` with `.cancelled` so the UI can offer
    /// "Try again"; after it, a no-op, so the token exchange still finishes.
    func cancelRedirectWait() { server?.cancel() }

    /// API base, resolved by `AppConfig`: localhost on the simulator, the Mac's
    /// Tailscale name on a physical device, overridable via UserDefaults.
    static var apiBase: String { AppConfig.apiBase }

    /// Full loopback OAuth in one call: spins up a local listener, hands the consent
    /// URL to `present` (shown in SFSafariViewController), waits for the 127.0.0.1
    /// redirect, and exchanges the code for tokens. Throws on any failure; the caller
    /// just shows the connecting state and stores the returned tokens.
    func connect(provider: OAuthProvider, loginHint: String? = nil, present: (URL) -> Void) async throws -> ConnectedTokens {
        let server = try LoopbackServer()
        self.server = server
        let port = await server.start()
        let state = UUID().uuidString
        // PKCE (RFC 7636, S256): defense-in-depth for the native loopback flow so an
        // intercepted authorization code can't be redeemed without the verifier.
        let pkce = PKCE()
        // Cancelling the surrounding Task (e.g. the user taps Cancel) tears down the
        // loopback listener, which unblocks `awaitCallback` with `.cancelled`.
        return try await withTaskCancellationHandler {
            do {
                let (url, redirect) = try await authorizeURL(provider: provider, port: port, state: state, challenge: pkce.challenge, loginHint: loginHint)
                present(url)
                let (code, returnedState) = try await server.awaitCallback()
                guard returnedState == state else { throw OAuthError.server("State mismatch") }
                return try await complete(provider: provider, code: code, redirectUri: redirect, verifier: pkce.verifier)
            } catch {
                server.cancel()
                throw error
            }
        } onCancel: {
            server.cancel()
        }
    }

    /// Fetch the provider consent URL for a loopback redirect on `port`. Passes the
    /// PKCE `code_challenge` (S256) so the proxy can forward it to the provider.
    func authorizeURL(provider: OAuthProvider, port: UInt16, state: String, challenge: String, loginHint: String? = nil) async throws -> (url: URL, redirectUri: String) {
        let redirect = "http://127.0.0.1:\(port)/oauth-callback"
        var comps = URLComponents(string: "\(Self.apiBase)/auth/\(provider.apiSegment)/authorize")!
        var items: [URLQueryItem] = [
            .init(name: "redirect_uri", value: redirect),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        // Reconnect: pre-select the account being re-authenticated so the provider's
        // picker doesn't default to a different signed-in account. The proxy forwards
        // login_hint to Google/Microsoft.
        if let loginHint, !loginHint.isEmpty { items.append(.init(name: "login_hint", value: loginHint)) }
        comps.queryItems = items
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        try Self.ensureOK(resp, data, "authorize")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = obj["auth_url"] as? String, let url = URL(string: urlStr) else {
            throw OAuthError.server("Bad authorize response")
        }
        Log.engine.info("oauth: got auth_url for \(provider.rawValue, privacy: .public)")
        return (url, redirect)
    }

    /// Exchange the code for tokens, then read the account email. Sends the PKCE
    /// `code_verifier` so the provider can match it against the earlier challenge.
    func complete(provider: OAuthProvider, code: String, redirectUri: String, verifier: String) async throws -> ConnectedTokens {
        var req = URLRequest(url: URL(string: "\(Self.apiBase)/auth/\(provider.apiSegment)/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["code": code, "redirect_uri": redirectUri, "code_verifier": verifier])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.ensureOK(resp, data, "token exchange")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw OAuthError.server("Bad token response")
        }
        let refresh = obj["refresh_token"] as? String
        let email = try await fetchEmail(provider: provider, accessToken: access)
        Log.engine.info("oauth: completed for \(email)")
        return ConnectedTokens(email: email, accessToken: access, refreshToken: refresh)
    }

    /// Read the signed-in user's email from the provider.
    private func fetchEmail(provider: OAuthProvider, accessToken: String) async throws -> String {
        let url: URL = provider == .google
            ? URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
            : URL(string: "https://graph.microsoft.com/v1.0/me")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.ensureOK(resp, data, "profile")
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let email = (obj?["email"] as? String)
            ?? (obj?["mail"] as? String)
            ?? (obj?["userPrincipalName"] as? String)
        guard let email, !email.isEmpty else { throw OAuthError.noEmail }
        return email
    }

    private static func ensureOK(_ resp: URLResponse, _ data: Data, _ what: String) throws {
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.server("\(what) failed: \(body.prefix(200))")
        }
    }
}

/// A PKCE (RFC 7636) verifier/challenge pair. The `verifier` is 32 bytes of CSPRNG
/// entropy, base64url-encoded; the `challenge` is its SHA-256, base64url-encoded
/// (the S256 method). The verifier is sent only on the token exchange, the challenge
/// only on the authorize request — so an authorization code lifted from the loopback
/// redirect is useless without the verifier that never left the device.
struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncodedString()
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    /// Base64url (RFC 4648 §5): `+`→`-`, `/`→`_`, no `=` padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A minimal loopback HTTP listener that captures the single OAuth redirect
/// (`GET /oauth-callback?code=…&state=…`) and returns a tiny success page. Bound to
/// an ephemeral port; the caller reads `port` after `start()`.
final class LoopbackServer: @unchecked Sendable {   // all access serialized on `queue`
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?
    private var pending: Result<(code: String, state: String), Error>?
    private let queue = DispatchQueue(label: "com.inbox2.oauth.loopback")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
    }

    /// Start listening; resolves with the ephemeral port once ready.
    func start() async -> UInt16 {
        await withCheckedContinuation { cont in
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let p = self?.listener.port?.rawValue {
                    self?.port = p
                    Log.engine.info("oauth: loopback listening on \(p)")
                    cont.resume(returning: p)
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Await the redirect (resolves immediately if it already arrived).
    func awaitCallback() async throws -> (code: String, state: String) {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let pending = self.pending { cont.resume(with: pending); return }
                self.continuation = cont
            }
        }
    }

    /// Serialized on `queue` and buffered like `deliver`, so a cancel that lands
    /// before `awaitCallback` registers still unblocks it (no hung "Connecting…").
    func cancel() {
        queue.async {
            self.deliver(.failure(OAuthError.cancelled))
        }
    }

    /// Deliver the parsed result to a waiting awaiter, or buffer it.
    /// First result wins: a later cancel (browser closed after the redirect) is dropped.
    private func deliver(_ result: Result<(code: String, state: String), Error>) {
        guard pending == nil else { return }
        pending = result
        if let c = continuation { continuation = nil; c.resume(with: result) }
        listener.cancel()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            // First line: "GET /oauth-callback?code=…&state=… HTTP/1.1"
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let body = "<html><body style='font:16px -apple-system;text-align:center;padding:40px'>You're signed in. Return to Inbox2.</body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })

            let comps = URLComponents(string: "http://127.0.0.1\(path)")
            if let code = comps?.queryItems?.first(where: { $0.name == "code" })?.value {
                let state = comps?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
                self.deliver(.success((code, state)))
            } else if let err = comps?.queryItems?.first(where: { $0.name == "error" })?.value {
                self.deliver(.failure(OAuthError.server(err)))
            }
        }
    }
}
