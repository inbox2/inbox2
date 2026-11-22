import Combine
import Foundation

// Touch Strip state for the iPad (docs/Touch-Strip.md): the synced layout, the
// pinned/hidden mode, and the polled data feeds. Port of the store half of
// `ui/web/src/lib/touchStrip.js` + `hooks/useStripFeed.js`.

// MARK: - Payloads (`GET /api/v1/strip/*`, StripSerializers)

struct StripQuote: Decodable, Hashable {
    let symbol: String
    let name: String?
    let price: Double?
    let change_pct: Double?
    let currency: String?
    let spark: [Double]?
}

struct StripMatch: Decodable, Hashable {
    let symbol: String
    let name: String?
    let kind: String?
    let exchange: String?
}

struct StripPlaceMatch: Decodable, Hashable {
    let name: String
    let region: String?
    let country: String?
    let lat: Double
    let lon: Double
    let timezone: String?
}

struct StripHour: Decodable, Hashable {
    let time: String
    let temp_c: Int?
    let code: Int?
}

struct StripForecast: Decodable {
    let place: String?
    let temp_c: Int
    let code: Int?
    let is_day: Bool?
    let high_c: Int?
    let low_c: Int?
    let hourly: [StripHour]
    let rain: [RainSlot]
}

struct StripIpInfo: Decodable {
    let ip: String
    let country: String?
    let country_code: String?
    let city: String?
    let isp: String?
    let proxy: Bool?
}

struct StripHeadline: Decodable, Hashable {
    let feed: String
    let source: String?
    let title: String
    let url: String
    let published_at: String?
}

/// The strip endpoints. Feeds are public (`authed: false`); the layout is the user's.
@MainActor enum StripAPI {
    private struct Quotes: Decodable { let quotes: [StripQuote] }
    private struct Matches: Decodable { let matches: [StripMatch] }
    private struct Places: Decodable { let places: [StripPlaceMatch] }
    private struct Forecast: Decodable { let forecast: StripForecast }
    private struct Ip: Decodable { let ip: StripIpInfo }
    private struct Headlines: Decodable { let headlines: [StripHeadline] }
    private struct Layout: Decodable { let touch_strip: SavedStrip? }

    private static var client: CloudClient { CloudSession.shared.mailClient() }

    /// Strict query encoding: `+`, `&`, `=` and `,` inside a value must not reach Rails raw.
    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    static func quotes(_ symbols: [String]) async throws -> [StripQuote] {
        let r: Quotes = try await client.request("GET", "/strip/quotes?symbols=\(enc(symbols.joined(separator: ",")))", authed: false)
        return r.quotes
    }

    static func symbols(_ q: String) async throws -> [StripMatch] {
        let r: Matches = try await client.request("GET", "/strip/symbols?q=\(enc(q))", authed: false)
        return r.matches
    }

    static func places(_ q: String) async throws -> [StripPlaceMatch] {
        let r: Places = try await client.request("GET", "/strip/places?q=\(enc(q))", authed: false)
        return r.places
    }

    static func weather(_ place: StripPlace) async throws -> StripForecast {
        var path = "/strip/weather"
        if !place.isCurrent, let lat = place.lat, let lon = place.lon {
            path += "?lat=\(lat)&lon=\(lon)&place=\(enc(place.label ?? ""))"
        }
        let r: Forecast = try await client.request("GET", path, authed: false)
        return r.forecast
    }

    static func ip() async throws -> StripIpInfo {
        let r: Ip = try await client.request("GET", "/strip/ip", authed: false)
        return r.ip
    }

    static func news(_ urls: [String]) async throws -> [StripHeadline] {
        // `[]` encoded here: a raw bracket makes URL(string:) re-encode the whole query,
        // so the feed URLs reached Rails as %253A… and it answered 400.
        let qs = urls.map { "feeds%5B%5D=\(enc($0))" }.joined(separator: "&")
        let r: Headlines = try await client.request("GET", "/strip/news?\(qs)", authed: false)
        return r.headlines
    }

    static func loadLayout() async throws -> SavedStrip? {
        let r: Layout = try await client.request("GET", "/account/touch-strip", authed: true)
        return r.touch_strip
    }

    static func saveLayout(_ config: StripConfig) async throws {
        let data = try JSONEncoder().encode(config)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        try await client.requestVoid("PUT", "/account/touch-strip", body: ["touch_strip": dict], authed: true)
    }
}

// MARK: - Feeds

/// Polled feed data, cached per key at module level so compact ↔ expanded and the
/// customize previews paint the last data at once and only refetch when stale.
/// Polling pauses while the app is in the background (`active`, set from scenePhase).
/// The server caches every upstream too, so the interval is about freshness, not load.
@MainActor final class StripFeedStore: ObservableObject {
    static let shared = StripFeedStore()

    @Published private var values: [String: Any] = [:]
    private var triedAt: [String: Date] = [:]
    private var inFlight = Set<String>()
    var active = true

    static let minute: TimeInterval = 60

    func value<T>(_ key: String?) -> T? { key.flatMap { values[$0] as? T } }

    /// Run for as long as the calling view's `.task` lives. Several views may poll the
    /// same key; the staleness check + in-flight set keep it to one request.
    func poll<T>(_ key: String, every interval: TimeInterval, _ fetch: @escaping () async throws -> T) async {
        while !Task.isCancelled {
            if active, !inFlight.contains(key), Date().timeIntervalSince(triedAt[key] ?? .distantPast) >= interval {
                inFlight.insert(key)
                // A failure keeps the last good data; the next interval retries.
                if let v = try? await fetch() {
                    values[key] = v
                    triedAt[key] = Date()
                } else {
                    // A failed fetch tries again in 15 s, not a whole interval later.
                    triedAt[key] = Date().addingTimeInterval(min(15, interval) - interval)
                }
                inFlight.remove(key)
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

// MARK: - Layout + mode

enum TouchStripMode: String { case pinned, hidden }

@MainActor final class TouchStripModel: ObservableObject {
    static let shared = TouchStripModel()

    /// UserDefaults key for the mode; the same key works with `@AppStorage("ipad.touchStrip")`.
    static let modeKey = "ipad.touchStrip"
    private static let configKey = "ipad.touchStripConfig"

    @Published private(set) var config: StripConfig
    @Published var mode: TouchStripMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// True once the account copy loaded — only then do saves go up.
    private var remote = false
    private var saveTask: Task<Void, Never>?
    private var sessionWatch: AnyCancellable?

    private init() {
        // Paint first from this device's copy, when it is this person's (or nobody's yet).
        let local = UserDefaults.standard.data(forKey: Self.configKey).flatMap { try? JSONDecoder().decode(SavedStrip.self, from: $0) }
        let owner = UserDefaults.standard.string(forKey: Self.ownerKey)
        // Not known yet while the session restores: keep the copy; loadRemote checks again.
        let uid = CloudSession.shared.user?.id
        let mine = owner == nil || uid == nil || owner == uid
        config = mergeConfig(mine ? local : nil)
        mode = TouchStripMode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .pinned
        sessionWatch = CloudSession.shared.$state.removeDuplicates().sink { [weak self] state in
            guard let self else { return }
            if state == .loading { return }    // session restore: keep the cached layout
            if state == .signedIn { Task { await self.loadRemote() } } else {
                // Signed out: a save still waiting must not reach the next account.
                self.remote = false
                self.saveTask?.cancel()
                // Nothing of the last account's stays on screen (the device copy stays, owned).
                self.config = .defaults()
            }
        }
    }

    /// Pinned ↔ hidden (for the command palette).
    func toggle() { mode = mode == .pinned ? .hidden : .pinned }

    /// Apply an edit: saved on this device at once, to the account after 800ms.
    func update(_ edit: (inout StripConfig) -> Void) {
        var next = config
        edit(&next)
        set(next)
    }

    func reset() { set(.defaults()) }

    private func set(_ next: StripConfig) {
        var next = next
        revision += 1
        next.items = next.items.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        config = next
        storeLocal()
        guard remote else { return }
        saveTask?.cancel()
        let owner = CloudSession.shared.user?.id
        saveTask = Task { [config] in
            try? await Task.sleep(for: .milliseconds(800))
            // Only to the account that made the edit.
            guard !Task.isCancelled, owner != nil, CloudSession.shared.user?.id == owner else { return }
            do { try await StripAPI.saveLayout(config) }
            catch { Log.cloud.error("touch strip save failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Whose layout the device copy is, so a second account never inherits the first's.
    private static let ownerKey = "ipad.touchStripOwner"
    /// Bumped by every edit: a layout fetch that started before an edit keeps the edit.
    private var revision = 0

    private func storeLocal() {
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: Self.configKey) }
        if let uid = CloudSession.shared.user?.id { UserDefaults.standard.set(uid, forKey: Self.ownerKey) }
    }

    /// Pull the account's strip. An account that never saved one adopts this
    /// device's layout (pushes it up) rather than resetting it to defaults.
    func loadRemote() async {
        guard let uid = CloudSession.shared.user?.id else { return }
        let startedAt = revision
        do {
            let saved = try await StripAPI.loadLayout()
            // Signed out or switched account meanwhile: this answer is not theirs.
            guard CloudSession.shared.user?.id == uid else { return }
            remote = true
            let owner = UserDefaults.standard.string(forKey: Self.ownerKey)
            let deviceIsTheirs = owner == nil || owner == uid
            if revision != startedAt && deviceIsTheirs {
                set(config)                      // edited while loading: the edit wins
            } else if let saved, saved.hasSaved {
                config = mergeConfig(saved)
                storeLocal()
            } else if deviceIsTheirs {
                set(config)                      // first save: adopt this device's layout
            } else {
                set(.defaults())                 // another account's layout: start fresh
            }
        } catch {
            Log.cloud.error("touch strip load failed: \(String(describing: error), privacy: .public)")
        }
    }
}
