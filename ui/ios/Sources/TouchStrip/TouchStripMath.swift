import Foundation

// Touch Strip (docs/Touch-Strip.md) — the iPad port of `ui/web/src/lib/touchStrip.js`:
// the widget registry, the default layout + `mergeConfig`, and the pure maths the
// widgets draw with (treemap, time zones, rain). Foundation only, so the hostless
// Inbox2Tests target compiles it (Tests/TouchStripMathTests.swift).

// MARK: - Widgets

/// Mirrors `User::TOUCH_STRIP_ITEMS` (the API rejects anything else).
enum StripWidget: String, CaseIterable, Codable, Identifiable {
    case clocks, weather, stocks, crypto, news, ip
    var id: String { rawValue }

    var label: String {
        switch self {
        case .clocks: return "World clocks"
        case .weather: return "Weather"
        case .stocks: return "Stocks"
        case .crypto: return "Crypto"
        case .news: return "News"
        case .ip: return "Public IP"
        }
    }

    var hint: String {
        switch self {
        case .clocks: return "Up to 6 cities, meeting planner"
        case .weather: return "Your location or chosen cities"
        case .stocks: return "Watchlist treemap"
        case .crypto: return "Prices with 24h sparklines"
        case .news: return "Headlines from RSS feeds"
        case .ip: return "Tap to copy, flags VPNs"
        }
    }

    /// SF Symbol for the palette tile and the order row.
    var icon: String {
        switch self {
        case .clocks: return "clock"
        case .weather: return "cloud.sun"
        case .stocks: return "square.split.2x2"
        case .crypto: return "bitcoinsign.circle"
        case .news: return "newspaper"
        case .ip: return "globe"
        }
    }

    /// Tapping the key opens a full-width view (the IP key copies instead).
    var expands: Bool { self != .ip }
}

enum StripSection: String { case clocks, places, stocks, crypto, feeds }

func stripLimit(_ section: StripSection) -> Int {
    switch section {
    case .clocks: return 6
    case .places: return 3
    case .stocks: return 24
    case .crypto: return 8
    case .feeds: return 6
    }
}

enum StockSize: String, Codable, CaseIterable { case equal, weight }
let cryptoCurrencies = ["EUR", "USD"]

// MARK: - Config (`users.touch_strip`)

struct StripClock: Codable, Equatable, Hashable {
    var label: String
    var tz: String
}

/// `{label, lat, lon}` or `{current: true}` (weather where the caller's IP is).
struct StripPlace: Codable, Equatable, Hashable {
    var label: String?
    var lat: Double?
    var lon: Double?
    var current: Bool?
    var isCurrent: Bool { current == true }
    static let here = StripPlace(current: true)
    var feedKey: String { isCurrent ? "weather:here" : "weather:\(lat ?? 0),\(lon ?? 0)" }
}

struct StripStock: Codable, Equatable, Hashable {
    var symbol: String
    var weight: Double

    init(symbol: String, weight: Double = 1) { self.symbol = symbol; self.weight = weight }

    // The web stores a number, but a hand-edited or older row may hold a string.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol)
        if let d = try? c.decode(Double.self, forKey: .weight) { weight = d }
        else if let s = try? c.decode(String.self, forKey: .weight), let d = Double(s) { weight = d }
        else { weight = 1 }
    }
}

struct StripFeed: Codable, Equatable, Hashable {
    var url: String
    var label: String
}

struct StripOptions: Codable, Equatable {
    var stock_size: StockSize
    var crypto_currency: String
}

struct StripConfig: Codable, Equatable {
    var items: [StripWidget]
    var clocks: [StripClock]
    var places: [StripPlace]
    var stocks: [StripStock]
    var crypto: [String]
    var feeds: [StripFeed]
    var options: StripOptions

    /// A preference default, not display data: the strip a new user starts from.
    static func defaults() -> StripConfig {
        let tz = localTimeZone()
        var seen = Set<String>()
        let clocks = [
            StripClock(label: shortLabel(tz), tz: tz),
            StripClock(label: "NYC", tz: "America/New_York"),
            StripClock(label: "SFO", tz: "America/Los_Angeles"),
            StripClock(label: "TYO", tz: "Asia/Tokyo"),
        ].filter { seen.insert($0.tz).inserted }
        return StripConfig(
            items: StripWidget.allCases,
            clocks: clocks,
            places: [.here],
            stocks: ["AAPL", "NVDA", "MSFT", "ASML.AS", "GOOGL", "AMZN"].map { StripStock(symbol: $0) },
            crypto: ["BTC", "ETH", "SOL"],
            feeds: [
                StripFeed(url: "https://feeds.nos.nl/nosnieuwsalgemeen", label: "NOS"),
                StripFeed(url: "https://hnrss.org/frontpage", label: "HN"),
            ],
            options: StripOptions(stock_size: .equal, crypto_currency: "EUR")
        )
    }
}

/// The account's copy as the API returns it: any section may be null (never saved).
/// Each section decodes on its own, so one malformed section keeps its default
/// instead of dropping the whole layout.
struct SavedStrip: Decodable {
    struct Options: Decodable { var stock_size: String?; var crypto_currency: String? }
    var items: [String]?
    var clocks: [StripClock]?
    var places: [StripPlace]?
    var stocks: [StripStock]?
    var crypto: [String]?
    var feeds: [StripFeed]?
    var options: Options?

    enum CodingKeys: String, CodingKey { case items, clocks, places, stocks, crypto, feeds, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try? c.decodeIfPresent([String].self, forKey: .items)
        clocks = try? c.decodeIfPresent([StripClock].self, forKey: .clocks)
        places = try? c.decodeIfPresent([StripPlace].self, forKey: .places)
        stocks = try? c.decodeIfPresent([StripStock].self, forKey: .stocks)
        crypto = try? c.decodeIfPresent([String].self, forKey: .crypto)
        feeds = try? c.decodeIfPresent([StripFeed].self, forKey: .feeds)
        options = try? c.decodeIfPresent(Options.self, forKey: .options)
    }

    /// True when the account saved at least one section.
    var hasSaved: Bool {
        items != nil || clocks != nil || places != nil || stocks != nil || crypto != nil || feeds != nil || options != nil
    }
}

/// Saved sections win; a section the account never saved (null) keeps the default.
/// Unknown widget ids are dropped.
func mergeConfig(_ saved: SavedStrip?) -> StripConfig {
    var out = StripConfig.defaults()
    guard let saved else { return out }
    if let v = saved.items { out.items = v.compactMap(StripWidget.init(rawValue:)) }
    if let v = saved.clocks { out.clocks = v }
    if let v = saved.places { out.places = v }
    if let v = saved.stocks { out.stocks = v }
    if let v = saved.crypto { out.crypto = v }
    if let v = saved.feeds { out.feeds = v }
    if let o = saved.options {
        if let s = o.stock_size.flatMap(StockSize.init(rawValue:)) { out.options.stock_size = s }
        if let c = o.crypto_currency { out.options.crypto_currency = c }
    }
    return out
}

// MARK: - Labels

func localTimeZone() -> String { TimeZone.current.identifier }

/// "Europe/Amsterdam" → "AMS": the default short label for a clock.
func shortLabel(_ name: String) -> String {
    let last = name.split(separator: "/").last.map(String.init) ?? name
    let letters = String(last.filter { $0.isASCII && $0.isLetter }.prefix(3)).uppercased()
    return letters.isEmpty ? "UTC" : letters
}

/// "ASML.AS" → "ASML", "BTC-EUR" → "BTC", "^AEX" → "AEX": the tile label.
func tickerLabel(_ symbol: String) -> String {
    let s = symbol.hasPrefix("^") ? String(symbol.dropFirst()) : symbol
    return s.split(whereSeparator: { $0 == "." || $0 == "-" }).first.map(String.init) ?? s
}

// MARK: - Treemap (squarified, Bruls et al.)

struct TreemapCell<T> {
    let item: T
    let x: Double, y: Double, w: Double, h: Double
}

/// Items → cells tiling a W×H box, area ∝ value. Sorted largest first (stable on
/// ties, like the web's `Array.sort`), which keeps the cells close to square.
func squarify<T>(_ items: [T], value: (T) -> Double, width W: Double, height H: Double) -> [TreemapCell<T>] {
    let total = items.reduce(0) { $0 + max(value($1), 0) }
    guard total > 0, W > 0, H > 0 else { return [] }
    let scale = (W * H) / total
    let nodes = items.enumerated()
        .sorted { value($0.element) != value($1.element) ? value($0.element) > value($1.element) : $0.offset < $1.offset }
        .map { (item: $0.element, area: max(value($0.element), 0) * scale) }

    var out: [TreemapCell<T>] = []
    var x = 0.0, y = 0.0, w = W, h = H
    var row: [(item: T, area: Double)] = []

    func worst(_ r: [(item: T, area: Double)], _ side: Double) -> Double {
        let s = r.reduce(0) { $0 + $1.area }
        let mx = r.map(\.area).max() ?? 0, mn = r.map(\.area).min() ?? 0
        return max((side * side * mx) / (s * s), (s * s) / (side * side * mn))
    }
    func place() {
        let s = row.reduce(0) { $0 + $1.area }
        guard s > 0 else { row = []; return }
        if w >= h { // a column on the left
            let cw = s / h
            var yy = y
            for n in row { let nh = n.area / cw; out.append(TreemapCell(item: n.item, x: x, y: yy, w: cw, h: nh)); yy += nh }
            x += cw; w -= cw
        } else { // a row along the top
            let rh = s / w
            var xx = x
            for n in row { let nw = n.area / rh; out.append(TreemapCell(item: n.item, x: xx, y: y, w: nw, h: rh)); xx += nw }
            y += rh; h -= rh
        }
        row = []
    }
    var i = 0
    while i < nodes.count {
        let side = min(w, h)
        if row.isEmpty || worst(row + [nodes[i]], side) <= worst(row, side) { row.append(nodes[i]); i += 1 } else { place() }
    }
    place()
    return out
}

// MARK: - Market helpers

/// Day change → a colour step: flat, then three steps each way.
func changeBucket(_ pct: Double?) -> String {
    guard let pct, abs(pct) >= 0.05 else { return "flat" }
    let mag = abs(pct)
    let step = mag < 1 ? 1 : mag < 2.5 ? 2 : 3
    return "\(pct > 0 ? "up" : "down")\(step)"
}

/// Weighted mean of the day change — the watchlist's one headline number.
func weightedChange(_ quotes: [(symbol: String, change: Double?)], weightOf: (String) -> Double) -> Double? {
    var sum = 0.0, wsum = 0.0
    for q in quotes {
        guard let c = q.change else { continue }
        let w = weightOf(q.symbol)
        sum += c * w; wsum += w
    }
    return wsum > 0 ? sum / wsum : nil
}

func formatPrice(_ n: Double?) -> String {
    guard let n else { return "—" }
    let digits = abs(n) >= 1000 ? 0 : abs(n) >= 1 ? 2 : 4
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = digits
    f.maximumFractionDigits = digits
    return f.string(from: NSNumber(value: n)) ?? String(n)
}

func formatPct(_ n: Double?) -> String {
    guard let n else { return "" }
    return "\(n > 0 ? "+" : n < 0 ? "−" : "")\(String(format: "%.2f", abs(n)))%"
}

// MARK: - Time zones

private func utcMinutes(_ date: Date) -> Int {
    let m = Int(floor(date.timeIntervalSince1970 / 60)) % 1440
    return (m + 1440) % 1440
}

/// Minutes east of UTC for `tz` at `date` (DST-correct).
func tzOffsetMinutes(_ tz: String, _ date: Date = Date()) -> Int {
    (TimeZone(identifier: tz)?.secondsFromGMT(for: date) ?? 0) / 60
}

/// Minutes past midnight in `tz`.
func minutesInZone(_ tz: String, _ date: Date = Date()) -> Int {
    ((utcMinutes(date) + tzOffsetMinutes(tz, date)) % 1440 + 1440) % 1440
}

/// "+7", "−6", "+5:30" relative to `baseTz`; "" when the same.
func relativeOffset(_ tz: String, _ baseTz: String, _ date: Date = Date()) -> String {
    let d = tzOffsetMinutes(tz, date) - tzOffsetMinutes(baseTz, date)
    guard d != 0 else { return "" }
    let a = abs(d)
    return "\(d > 0 ? "+" : "−")\(a / 60)\(a % 60 != 0 ? String(format: ":%02d", a % 60) : "")"
}

let workStart = 9 * 60
let workEnd = 17 * 60
private let slotMinutes = 15

/// A city's 09:00–17:00 on the viewer's 24h axis, as [start, end) minute spans
/// (two when it wraps past midnight).
func workingSpans(_ tz: String, _ baseTz: String, _ date: Date = Date()) -> [[Int]] {
    let shift = tzOffsetMinutes(tz, date) - tzOffsetMinutes(baseTz, date)
    let start = ((workStart - shift) % 1440 + 1440) % 1440
    let end = start + (workEnd - workStart)
    return end <= 1440 ? [[start, end]] : [[start, 1440], [0, end - 1440]]
}

/// The longest window (viewer-local minutes) where every zone is in working
/// hours, or nil when there is none.
func sharedWindow(_ tzs: [String], _ baseTz: String, _ date: Date = Date()) -> [Int]? {
    guard !tzs.isEmpty else { return nil }
    var slots = Array(repeating: true, count: 1440 / slotMinutes)
    for tz in tzs {
        let spans = workingSpans(tz, baseTz, date)
        for i in slots.indices where slots[i] {
            let m = i * slotMinutes
            if !spans.contains(where: { m >= $0[0] && m < $0[1] }) { slots[i] = false }
        }
    }
    var best: (Int, Int)?
    var runStart: Int?
    for (i, ok) in (slots + [false]).enumerated() {
        if ok, runStart == nil { runStart = i }
        if !ok, let s = runStart {
            if best == nil || i - s > best!.1 - best!.0 { best = (s, i) }
            runStart = nil
        }
    }
    return best.map { [$0.0 * slotMinutes, $0.1 * slotMinutes] }
}

/// Rough phase of the day from local clock time alone (the clocks know a zone,
/// not a latitude). ponytail: fixed hours; real sunrise needs coordinates per city.
enum DayPhase: String { case night, dawn, day, dusk }
func dayPhase(_ minutes: Int) -> DayPhase {
    if minutes < 360 || minutes >= 1260 { return .night }
    if minutes < 450 { return .dawn }
    if minutes >= 1170 { return .dusk }
    return .day
}

func formatMinutes(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }

// MARK: - Weather

/// WMO weather code → SF Symbol.
func weatherIcon(_ code: Int?, _ isDay: Bool = true) -> String {
    guard let code else { return "cloud" }
    if code <= 1 { return isDay ? "sun.max.fill" : "moon.fill" }
    if code == 2 { return isDay ? "cloud.sun" : "cloud" }
    if code == 3 { return "cloud" }
    if code == 45 || code == 48 { return "cloud.fog" }
    if (71...77).contains(code) || code == 85 || code == 86 { return "cloud.snow" }
    if code >= 95 { return "cloud.bolt" }
    return "cloud.rain"
}

/// One 15-minute precipitation slot from the forecast.
struct RainSlot: Codable, Equatable, Hashable { let time: String; let mm: Double }

private func hhmm(_ iso: String) -> String {
    let chars = Array(iso)
    return chars.count >= 16 ? String(chars[11..<16]) : ""
}

/// Open-Meteo's 15-minute precipitation slots → one line: when it starts / stops.
func rainSummary(_ rain: [RainSlot]?) -> String? {
    guard let rain, !rain.isEmpty else { return nil }
    let wet = rain.map { $0.mm >= 0.1 }
    let hours = Int((Double(rain.count * slotMinutes) / 60).rounded())
    guard wet.contains(true) else { return "Dry for \(hours)h" }
    if wet[0] {
        guard let dry = wet.firstIndex(of: false) else { return "Rain for the next \(hours)h" }
        return "Rain until ~\(hhmm(rain[dry].time))"
    }
    return "Rain from \(hhmm(rain[wet.firstIndex(of: true)!].time))"
}
