import SwiftUI
import UIKit

// The Touch Strip's keys (port of `StripWidgets.jsx`). Each widget takes the
// config and renders its compact key(s) or — `expanded` — the full-width view.
// Every key is followed by a hairline divider. Data comes through
// StripFeedStore (cached per key, so compact ↔ expanded is instant).

/// Drawable height inside a key (strip 55pt − padding).
let stripBarHeight: CGFloat = 37

// MARK: - Market palette

/// The strip's own rainbow (web `--strip-*`), the same in every theme rather than
/// the theme accents, which some themes mute to near-grey. Dark labels on the
/// pastel tiles; the light bar deepens the steps and goes back to white labels.
struct StripColors {
    let up, down, flat, up1, up2, up3, down1, down2, down3, tileText, night, dusk, day, rain, sun: Color

    init(dark: Bool) {
        if dark {
            up = Color(hex: "44c2b3"); down = Color(hex: "f2785c"); flat = Color(hex: "8d8994")
            up1 = Color(hex: "3b9c90"); up2 = Color(hex: "44c2b3"); up3 = Color(hex: "6fd6c9")
            down1 = Color(hex: "d9654b"); down2 = Color(hex: "f2785c"); down3 = Color(hex: "f69a84")
            tileText = Color(hex: "141416")
            night = Color(hex: "4b3f80"); dusk = Color(hex: "f0a3bd"); day = Color(hex: "f0b545")
            rain = Color(hex: "a68cf0"); sun = Color(hex: "f0b545")
        } else {
            up = Color(hex: "1d7f73"); down = Color(hex: "c4472c"); flat = Color(hex: "9aa0a8")
            up1 = Color(hex: "4fb3a7"); up2 = Color(hex: "2f9a8d"); up3 = Color(hex: "1f7f74")
            down1 = Color(hex: "e88a74"); down2 = Color(hex: "dc6447"); down3 = Color(hex: "c24a30")
            tileText = .white
            night = Color(hex: "6b5fa8"); dusk = Color(hex: "e08aa8"); day = Color(hex: "e0a93a")
            rain = Color(hex: "8c74e0"); sun = Color(hex: "c98f1f")
        }
    }

    func bucket(_ name: String) -> Color {
        switch name {
        case "up1": return up1
        case "up2": return up2
        case "up3": return up3
        case "down1": return down1
        case "down2": return down2
        case "down3": return down3
        default: return flat
        }
    }

    func phase(_ p: DayPhase) -> Color {
        switch p {
        case .night: return night
        case .dawn, .dusk: return dusk
        case .day: return day
        }
    }
}

// MARK: - Shared bits

struct StripDivider: View {
    @Environment(\.theme) private var theme
    var body: some View { Rectangle().fill(theme.palette.borderSubtle).frame(width: 1).padding(.vertical, 9) }
}

/// Text roles of the strip (web `.label`, `.value`, `.sub`, `.big`, `.micro`).
enum StripText {
    static let label = AppFont.glyph(10, .semibold)
    static let value = AppFont.glyph(13, .semibold)
    static let sub = AppFont.glyph(11)
    static let big = AppFont.glyph(20, .semibold)
    static let micro = AppFont.glyph(9, .medium)
}

private extension View {
    /// One key segment: padded, full strip height.
    func stripKey(grow: Bool = false) -> some View {
        padding(.horizontal, 12)
            .frame(maxWidth: grow ? .infinity : nil, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

private struct KeyLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text.uppercased()).font(StripText.label).tracking(0.5).foregroundStyle(theme.palette.textTertiary).lineLimit(1)
    }
}

private struct Loading: View {
    @Environment(\.theme) private var theme
    var body: some View { Text("Loading…").font(StripText.sub).foregroundStyle(theme.palette.textTertiary) }
}

private func dirColor(_ pct: Double?, _ c: StripColors, _ p: ThemePalette) -> Color {
    guard let pct else { return p.textTertiary }
    return pct > 0 ? c.up : pct < 0 ? c.down : p.textTertiary
}

/// A key that opens its full-width view, or a static key when `onExpand` is nil
/// (the customize previews).
private struct KeyButton<Content: View>: View {
    let onExpand: (() -> Void)?
    var grow = false
    var label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        if let onExpand {
            Button(action: onExpand) { content().stripKey(grow: grow) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
        } else {
            content().stripKey(grow: grow)
        }
    }
}

struct Sparkline: View {
    @Environment(\.theme) private var theme
    let values: [Double]?
    var width: CGFloat = 48
    var height: CGFloat = 22
    let pct: Double?

    var body: some View {
        if let v = values, v.count >= 2 {
            let lo = v.min() ?? 0, span = ((v.max() ?? 0) - lo) == 0 ? 1 : (v.max() ?? 0) - lo
            Canvas { ctx, size in
                var path = Path()
                for (i, value) in v.enumerated() {
                    let pt = CGPoint(x: Double(i) / Double(v.count - 1) * size.width,
                                     y: size.height - 1 - (value - lo) / span * (size.height - 2))
                    i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                }
                ctx.stroke(path, with: .color(dirColor(pct, StripColors(dark: theme.palette.isDark), theme.palette)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
        }
    }
}

/// The widget for an id (shared by the strip and the customize previews).
struct StripWidgetView: View {
    let id: StripWidget
    let config: StripConfig
    var expanded = false
    var onExpand: (() -> Void)?
    /// False in the customize previews: look, don't touch (the IP key copies otherwise).
    var interactive = true

    var body: some View {
        switch id {
        case .clocks: ClocksWidget(config: config, expanded: expanded, onExpand: onExpand)
        case .weather: WeatherWidget(config: config, expanded: expanded, onExpand: onExpand)
        case .stocks: StocksWidget(config: config, expanded: expanded, onExpand: onExpand)
        case .crypto: CryptoWidget(config: config, expanded: expanded, onExpand: onExpand)
        case .news: NewsWidget(config: config, expanded: expanded, onExpand: onExpand)
        case .ip: IpWidget(interactive: interactive)
        }
    }
}

// MARK: - World clocks

private struct ClocksWidget: View {
    @Environment(\.theme) private var theme
    let config: StripConfig
    let expanded: Bool
    let onExpand: (() -> Void)?

    var body: some View {
        if !config.clocks.isEmpty {
            TimelineView(.periodic(from: .now, by: 15)) { tl in
                if expanded { ClockPlanner(clocks: config.clocks, now: tl.date) } else { compact(tl.date) }
            }
        }
    }

    private func compact(_ now: Date) -> some View {
        let base = localTimeZone()
        let colors = StripColors(dark: theme.palette.isDark)
        return Group {
            KeyButton(onExpand: onExpand, label: "World clocks. Open the meeting planner.") {
                HStack(spacing: 14) {
                    ForEach(Array(config.clocks.enumerated()), id: \.offset) { _, c in
                        let mins = minutesInZone(c.tz, now)
                        let phase = dayPhase(mins)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                KeyLabel(text: c.label)
                                Text(formatMinutes(mins)).font(AppFont.glyph(16, .semibold)).monospacedDigit()
                                    .foregroundStyle(theme.palette.textPrimary)
                                Text(relativeOffset(c.tz, base, now)).font(StripText.sub).foregroundStyle(theme.palette.textTertiary)
                            }
                            Canvas { ctx, size in
                                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(colors.phase(phase)))
                                ctx.fill(Path(CGRect(x: Double(mins) / 1440 * size.width - 0.8, y: 0, width: 1.6, height: size.height)),
                                         with: .color(theme.palette.textPrimary))
                            }
                            .frame(height: 4)
                        }
                        .frame(minWidth: 72)
                        .fixedSize()
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            StripDivider()
        }
    }
}

/// Each city's 09–17 on your local 24h axis, the now-line, and the longest
/// stretch where everyone is working.
private struct ClockPlanner: View {
    @Environment(\.theme) private var theme
    let clocks: [StripClock]
    let now: Date
    private let labelW: CGFloat = 84

    var body: some View {
        let base = localTimeZone()
        let tzs = clocks.map(\.tz).reduce(into: [base]) { if !$0.contains($1) { $0.append($1) } }
        let shared = sharedWindow(tzs, base, now)
        let colors = StripColors(dark: theme.palette.isDark)
        let p = theme.palette
        Group {
            Canvas { ctx, size in
                let n = clocks.count, gap = 2.0
                let laneH = max(3, (size.height - gap * Double(n - 1)) / Double(n))
                let labelled = n <= 4
                let left = labelled ? labelW : 0
                let axisW = max(size.width - left, 1)
                func x(_ m: Int) -> Double { left + Double(m) / 1440 * axisW }
                for (i, c) in clocks.enumerated() {
                    let y = Double(i) * (laneH + gap)
                    if labelled {
                        ctx.draw(Text("\(c.label) \(formatMinutes(minutesInZone(c.tz, now)))")
                                    .font(AppFont.glyph(9, .semibold)).foregroundStyle(p.textTertiary),
                                 at: CGPoint(x: 0, y: y + laneH / 2), anchor: .leading)
                    }
                    ctx.fill(Path(roundedRect: CGRect(x: x(0), y: y, width: axisW, height: laneH), cornerRadius: laneH / 2),
                             with: .color(colors.night.opacity(0.7)))
                    for s in workingSpans(c.tz, base, now) {
                        ctx.fill(Path(roundedRect: CGRect(x: x(s[0]), y: y, width: x(s[1]) - x(s[0]), height: laneH), cornerRadius: laneH / 2),
                                 with: .color(colors.day))
                    }
                }
                if let shared {
                    let r = Path(roundedRect: CGRect(x: x(shared[0]), y: 0, width: x(shared[1]) - x(shared[0]), height: size.height), cornerRadius: 3)
                    ctx.fill(r, with: .color(p.toggle.opacity(0.14)))
                    ctx.stroke(r, with: .color(p.toggle), lineWidth: 1.5)
                }
                let nowX = x(minutesInZone(base, now))
                ctx.fill(Path(roundedRect: CGRect(x: nowX - 1, y: 0, width: 2, height: size.height), cornerRadius: 1), with: .color(p.textPrimary))
            }
            .frame(minWidth: 240, idealWidth: 480, maxWidth: .infinity)
            .frame(height: stripBarHeight)
            .stripKey(grow: true)
            .accessibilityLabel("Working hours per city on your local day")
            StripDivider()
            HStack(spacing: 8) {
                StripChip(text: "Overlap")
                Text(shared.map { "\(formatMinutes($0[0])) – \(formatMinutes($0[1]))" } ?? "None today")
                    .font(StripText.value).monospacedDigit().foregroundStyle(p.textPrimary)
            }
            .stripKey()
            StripDivider()
        }
    }
}

struct StripChip: View {
    @Environment(\.theme) private var theme
    let text: String
    var on = true
    var body: some View {
        Text(text.uppercased())
            .font(StripText.label).tracking(0.5).lineLimit(1)
            .foregroundStyle(on ? theme.palette.textPrimary : theme.palette.textTertiary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? theme.palette.bgRaised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.palette.borderDefault, lineWidth: 1))
    }
}

// MARK: - Weather

private func placeName(_ place: StripPlace, _ f: StripForecast?) -> String { place.label ?? f?.place ?? "Here" }

/// Polls one place's forecast; hands it to `content`.
private struct PlaceWeather<Content: View>: View {
    @ObservedObject private var feeds = StripFeedStore.shared
    let place: StripPlace
    @ViewBuilder let content: (StripForecast?) -> Content
    var body: some View {
        content(feeds.value(place.feedKey))
            .task(id: place.feedKey) { await feeds.poll(place.feedKey, every: 10 * StripFeedStore.minute) { try await StripAPI.weather(place) } }
    }
}

private struct RainBars: View {
    @Environment(\.theme) private var theme
    let rain: [RainSlot]
    let count: Int
    var height: CGFloat = 18
    var body: some View {
        let slots = Array(rain.prefix(count))
        if !slots.isEmpty {
            Canvas { ctx, size in
                for (i, r) in slots.enumerated() {
                    let h = r.mm < 0.05 ? 1 : min(size.height, 2 + sqrt(r.mm) * 10)
                    ctx.fill(Path(roundedRect: CGRect(x: Double(i) * 4, y: size.height - h, width: 3, height: h), cornerRadius: 1),
                             with: .color(StripColors(dark: theme.palette.isDark).rain))
                }
            }
            .frame(width: CGFloat(slots.count * 4), height: height)
            .accessibilityHidden(true)
        }
    }
}

private struct WeatherWidget: View {
    @Environment(\.theme) private var theme
    let config: StripConfig
    let expanded: Bool
    let onExpand: (() -> Void)?

    private var p: ThemePalette { theme.palette }
    private var sun: Color { StripColors(dark: p.isDark).sun }

    var body: some View {
        if let first = config.places.first {
            let rest = Array(config.places.dropFirst())
            if expanded {
                detail(first)
                ForEach(rest, id: \.self) { place in
                    PlaceWeather(place: place) { mini(place, $0) }.stripKey()
                    StripDivider()
                }
            } else {
                KeyButton(onExpand: onExpand, label: "Weather. Show the next 12 hours.") {
                    HStack(spacing: 10) {
                        PlaceWeather(place: first) { main(first, $0) }
                        ForEach(rest, id: \.self) { place in PlaceWeather(place: place) { mini(place, $0) } }
                    }
                }
                StripDivider()
            }
        }
    }

    @ViewBuilder private func main(_ place: StripPlace, _ f: StripForecast?) -> some View {
        if let f {
            HStack(spacing: 8) {
                Image(systemName: weatherIcon(f.code, f.is_day ?? true)).font(AppFont.glyph(20)).foregroundStyle(sun)
                Text("\(f.temp_c)°").font(StripText.big).foregroundStyle(p.textPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    KeyLabel(text: placeName(place, f))
                    Text("\(f.low_c.map(String.init) ?? "–")° – \(f.high_c.map(String.init) ?? "–")°").font(StripText.sub).foregroundStyle(p.textTertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    RainBars(rain: f.rain, count: 8)
                    Text("rain · 2h").font(StripText.micro).foregroundStyle(p.textTertiary)
                }
                .accessibilityLabel(rainSummary(f.rain) ?? "")
            }
            .fixedSize()
        } else {
            Loading()
        }
    }

    private func mini(_ place: StripPlace, _ f: StripForecast?) -> some View {
        HStack(spacing: 5) {
            KeyLabel(text: placeName(place, f))
            Text(f.map { "\($0.temp_c)°" } ?? "—").font(StripText.value).foregroundStyle(p.textPrimary)
        }
        .fixedSize()
    }

    private func detail(_ place: StripPlace) -> some View {
        PlaceWeather(place: place) { f in
            if let f {
                HStack(spacing: 8) {
                    Image(systemName: "location").font(AppFont.glyph(12)).foregroundStyle(p.toggle)
                    Text(placeName(place, f)).font(StripText.value).foregroundStyle(p.textPrimary)
                    Image(systemName: weatherIcon(f.code, f.is_day ?? true)).font(AppFont.glyph(16)).foregroundStyle(sun)
                    Text("\(f.temp_c)°").font(StripText.big).foregroundStyle(p.textPrimary)
                }
                .fixedSize().stripKey()
                StripDivider()
                HStack(spacing: 0) {
                    ForEach(f.hourly, id: \.self) { h in
                        HStack(spacing: 4) {
                            Text(String(h.time.dropFirst(11).prefix(2))).font(StripText.sub).foregroundStyle(p.textTertiary)
                            Image(systemName: weatherIcon(h.code, true)).font(AppFont.glyph(12)).foregroundStyle(sun)
                            Text(h.temp_c.map { "\($0)°" } ?? "—").font(StripText.value).foregroundStyle(p.textPrimary)
                        }
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(minWidth: 300, idealWidth: 600, maxWidth: .infinity)
                .stripKey(grow: true)
                StripDivider()
                HStack(spacing: 8) {
                    RainBars(rain: f.rain, count: 16, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rainSummary(f.rain) ?? "").font(StripText.value).foregroundStyle(p.textPrimary)
                        Text("next 4 hours").font(StripText.sub).foregroundStyle(p.textTertiary)
                    }
                }
                .fixedSize().stripKey()
                StripDivider()
            } else {
                Loading().stripKey()
                StripDivider()
            }
        }
    }
}

// MARK: - Stocks

/// Polls quotes for a symbol list (stocks, and crypto as Yahoo pairs like BTC-EUR).
private struct QuoteFeed<Content: View>: View {
    @ObservedObject private var feeds = StripFeedStore.shared
    let symbols: [String]
    @ViewBuilder let content: ([StripQuote]) -> Content
    private var key: String? { symbols.isEmpty ? nil : "quotes:\(symbols.joined(separator: ","))" }
    var body: some View {
        content(feeds.value(key) ?? [])
            .task(id: key) {
                guard let key else { return }
                await feeds.poll(key, every: StripFeedStore.minute) { try await StripAPI.quotes(symbols) }
            }
    }
}

/// Size = weight (equal or the user's), colour = day change. Labels appear only
/// where the tile has room.
private struct Treemap: View {
    @Environment(\.theme) private var theme
    let quotes: [StripQuote]
    let weightOf: (String) -> Double
    var detailed = false

    var body: some View {
        let colors = StripColors(dark: theme.palette.isDark)
        Canvas { ctx, size in
            let cells = squarify(quotes, value: { weightOf($0.symbol) }, width: size.width, height: size.height)
            for c in cells {
                let q = c.item
                ctx.fill(Path(CGRect(x: c.x, y: c.y, width: max(c.w - 1, 0), height: max(c.h - 1, 0))),
                         with: .color(colors.bucket(changeBucket(q.change_pct))))
                let label = tickerLabel(q.symbol)
                let pct = formatPct(q.change_pct)
                let lw = Double(label.count) * 7
                guard c.w >= lw + 8 else { continue }
                let twoLines = c.h >= 26 && c.w >= 40
                let oneLinePct = !twoLines && c.w >= lw + 58
                let price = detailed && c.w >= lw + 124
                let ticker = ctx.resolve(Text(label).font(AppFont.glyph(10, .bold)).foregroundStyle(colors.tileText))
                let y1 = twoLines ? c.y + 10 : c.y + c.h / 2
                ctx.draw(ticker, at: CGPoint(x: c.x + 5, y: y1), anchor: .leading)
                var lineX = c.x + 5 + ticker.measure(in: size).width + 5
                var lineY = y1
                if twoLines { lineX = c.x + 5; lineY = c.y + 24 }
                if twoLines || oneLinePct {
                    let pctText = ctx.resolve(Text(pct).font(AppFont.glyph(10)).foregroundStyle(colors.tileText))
                    ctx.draw(pctText, at: CGPoint(x: lineX, y: lineY), anchor: .leading)
                    if price {
                        ctx.draw(Text(formatPrice(q.price)).font(AppFont.glyph(10)).foregroundStyle(colors.tileText.opacity(0.72)),
                                 at: CGPoint(x: lineX + pctText.measure(in: size).width + 5, y: lineY), anchor: .leading)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(quotes.map { "\(tickerLabel($0.symbol)) \(formatPct($0.change_pct))" }.joined(separator: ", "))
    }
}

private struct StocksWidget: View {
    @Environment(\.theme) private var theme
    let config: StripConfig
    let expanded: Bool
    let onExpand: (() -> Void)?

    var body: some View {
        if !config.stocks.isEmpty {
            QuoteFeed(symbols: config.stocks.map(\.symbol)) { quotes in
                let byWeight = config.options.stock_size == .weight
                let weights = Dictionary(config.stocks.map { ($0.symbol.uppercased(), byWeight ? max($0.weight, 0.1) : 1) }, uniquingKeysWith: { a, _ in a })
                let weightOf: (String) -> Double = { weights[$0.uppercased()] ?? 1 }
                let avg = weightedChange(quotes.map { ($0.symbol, $0.change_pct) }, weightOf: weightOf)
                let summary = VStack(alignment: .leading, spacing: 2) {
                    KeyLabel(text: expanded ? "Watchlist · \(quotes.count)" : "Watch")
                    Text(quotes.isEmpty ? "—" : formatPct(avg)).font(StripText.value).monospacedDigit()
                        .foregroundStyle(dirColor(avg, StripColors(dark: theme.palette.isDark), theme.palette))
                }.fixedSize()
                if expanded {
                    summary.stripKey()
                    StripDivider()
                    Treemap(quotes: quotes, weightOf: weightOf, detailed: true)
                        .frame(minWidth: 300, idealWidth: 700, maxWidth: .infinity)
                        .frame(height: stripBarHeight)
                        .stripKey(grow: true)
                    StripDivider()
                } else {
                    KeyButton(onExpand: onExpand, label: "Stocks. Open the full treemap.") {
                        HStack(spacing: 10) {
                            summary
                            if quotes.isEmpty { Loading() } else {
                                Treemap(quotes: quotes, weightOf: weightOf).frame(width: 300, height: stripBarHeight)
                            }
                        }
                    }
                    StripDivider()
                }
            }
        }
    }
}

// MARK: - Crypto

private struct CoinMain: View {
    @Environment(\.theme) private var theme
    let q: StripQuote
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                KeyLabel(text: tickerLabel(q.symbol))
                Text(formatPct(q.change_pct)).font(StripText.micro)
                    .foregroundStyle(dirColor(q.change_pct, StripColors(dark: theme.palette.isDark), theme.palette))
            }
            Text(formatPrice(q.price)).font(StripText.value).monospacedDigit().foregroundStyle(theme.palette.textPrimary)
        }
        .fixedSize()
    }
}

private struct CryptoWidget: View {
    @Environment(\.theme) private var theme
    let config: StripConfig
    let expanded: Bool
    let onExpand: (() -> Void)?

    var body: some View {
        let currency = config.options.crypto_currency
        if !config.crypto.isEmpty {
            QuoteFeed(symbols: config.crypto.map { "\($0)-\(currency)" }) { quotes in
                if expanded {
                    ForEach(quotes, id: \.symbol) { q in
                        HStack {
                            CoinMain(q: q)
                            Spacer(minLength: 8)
                            Sparkline(values: q.spark, width: 80, height: 26, pct: q.change_pct)
                        }
                        .frame(minWidth: 150, idealWidth: 180, maxWidth: .infinity)
                        .stripKey(grow: true)
                        StripDivider()
                    }
                } else {
                    KeyButton(onExpand: onExpand, label: "Crypto in \(currency). Show every coin.") {
                        HStack(spacing: 10) {
                            if let lead = quotes.first {
                                CoinMain(q: lead)
                                Sparkline(values: lead.spark, pct: lead.change_pct)
                            } else {
                                Loading()
                            }
                            if quotes.count > 1 {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(quotes.dropFirst().prefix(2), id: \.symbol) { q in
                                        HStack(spacing: 5) {
                                            KeyLabel(text: tickerLabel(q.symbol))
                                            Text(formatPrice(q.price)).foregroundStyle(theme.palette.textSecondary)
                                            Text(formatPct(q.change_pct))
                                                .foregroundStyle(dirColor(q.change_pct, StripColors(dark: theme.palette.isDark), theme.palette))
                                        }
                                        .font(StripText.sub).monospacedDigit()
                                    }
                                }
                                .fixedSize()
                            }
                        }
                    }
                    StripDivider()
                }
            }
        }
    }
}

// MARK: - News

private func feedLabel(_ feeds: [StripFeed], _ h: StripHeadline) -> String {
    feeds.first { $0.url == h.feed }?.label ?? h.source ?? ""
}

private struct NewsWidget: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @ObservedObject private var feeds = StripFeedStore.shared
    let config: StripConfig
    let expanded: Bool
    let onExpand: (() -> Void)?
    @State private var index = 0
    @State private var paused = false

    private var urls: [String] { config.feeds.map(\.url) }
    private var key: String? { urls.isEmpty ? nil : "news:\(urls.joined(separator: "|"))" }
    private var items: [StripHeadline] { feeds.value(key) ?? [] }

    var body: some View {
        if !config.feeds.isEmpty {
            Group {
                if expanded { NewsTicker(items: items, feeds: config.feeds) } else { compact }
            }
            .task(id: key) {
                guard let key else { return }
                await feeds.poll(key, every: 10 * StripFeedStore.minute) { try await StripAPI.news(urls) }
            }
        }
    }

    private var compact: some View {
        let count = items.count
        let h = count > 0 ? items[index % count] : nil
        let p = theme.palette
        return Group {
            HStack(spacing: 8) {
                Button { onExpand?() } label: { StripChip(text: h.map { feedLabel(config.feeds, $0) } ?? "News") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("News. Open the ticker.")
                if let h {
                    Button { URL(string: h.url).map { openURL($0) } } label: {
                        Text(h.title).font(StripText.value).foregroundStyle(p.textPrimary).lineLimit(1)
                            .frame(minWidth: 140, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    Loading().frame(minWidth: 140, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
                }
                if count > 0 {
                    Text("\(index % count + 1)/\(count)").font(StripText.sub).monospacedDigit().foregroundStyle(p.textTertiary)
                }
                StripIconButton(icon: "chevron.right", label: "Next headline", size: 24) { index += 1 }
                    .disabled(count < 2)
            }
            .stripKey(grow: true)
            .onHover { paused = $0 }
            .task(id: "\(paused)-\(count)") {
                guard !paused, count >= 2 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(8))
                    if !Task.isCancelled { index = (index + 1) % count }
                }
            }
            StripDivider()
        }
    }
}

/// Scrolling ticker at a constant 60pt/s; pauses on hover, stands still under
/// Reduce Motion (then it scrolls by hand).
private struct NewsTicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [StripHeadline]
    let feeds: [StripFeed]
    @State private var source: String?
    @State private var paused = false
    @State private var trackWidth: CGFloat = 0
    @State private var base: Double = 0
    @State private var startedAt = Date()

    private var shown: [StripHeadline] { source.map { s in items.filter { $0.feed == s } } ?? items }

    var body: some View {
        HStack(spacing: 6) {
            filter("All", on: source == nil) { source = nil }
            ForEach(feeds, id: \.url) { f in
                filter(f.label.isEmpty ? (URL(string: f.url)?.host ?? f.url) : f.label, on: source == f.url) { source = f.url }
            }
        }
        .fixedSize()
        .stripKey()
        StripDivider()
        Group {
            if reduceMotion {
                ScrollView(.horizontal, showsIndicators: false) { track(shown) }
            } else {
                TimelineView(.animation(paused: paused || trackWidth == 0)) { tl in
                    let travelled = base + (paused ? 0 : tl.date.timeIntervalSince(startedAt) * 60)
                    let x = trackWidth > 0 ? -travelled.truncatingRemainder(dividingBy: Double(trackWidth)) : 0
                    HStack(spacing: 0) {
                        track(shown).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
                        track(shown).accessibilityHidden(true)
                    }
                    .fixedSize()
                    .offset(x: x)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .clipped()
                .onHover { hovering in
                    if hovering, !paused { base += Date().timeIntervalSince(startedAt) * 60 }
                    if !hovering { startedAt = Date() }
                    paused = hovering
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 700, maxWidth: .infinity)
        .stripKey(grow: true)
        .onChange(of: source) { base = 0; startedAt = Date() }
        StripDivider()
    }

    private func filter(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { StripChip(text: text, on: on) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func track(_ list: [StripHeadline]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, h in
                Button { URL(string: h.url).map { openURL($0) } } label: {
                    HStack(spacing: 6) {
                        Text(feedLabel(feeds, h).uppercased()).font(StripText.label).tracking(0.5).foregroundStyle(theme.palette.toggle)
                        Text(h.title).font(StripText.value).foregroundStyle(theme.palette.textPrimary).lineLimit(1)
                    }
                    .padding(.trailing, 28)
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }
}

// MARK: - Public IP

private struct IpWidget: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var feeds = StripFeedStore.shared
    /// False in the customize preview: look, don't copy.
    let interactive: Bool
    @State private var copied = false

    var body: some View {
        let info: StripIpInfo? = feeds.value("ip")
        let p = theme.palette
        let proxy = info?.proxy == true
        let detail = [info?.country_code, proxy ? "VPN / proxy" : info?.isp].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        Group {
            Button {
                guard interactive, let ip = info?.ip else { return }
                UIPasteboard.general.string = ip
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: proxy ? "checkmark.shield.fill" : "checkmark.shield").font(AppFont.glyph(14))
                        .foregroundStyle(proxy ? p.toggle : p.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copied ? "Copied" : info?.ip ?? "—").font(AppFont.mono(12, .semibold)).foregroundStyle(p.textPrimary)
                        if !detail.isEmpty { Text(detail).font(StripText.sub).foregroundStyle(p.textTertiary).lineLimit(1) }
                    }
                }
                .fixedSize()
                .stripKey()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Public IP \(info?.ip ?? ""). Tap to copy.")
            StripDivider()
        }
        .task { await feeds.poll("ip", every: 10 * StripFeedStore.minute) { try await StripAPI.ip() } }
    }
}

// MARK: - Icon button in a bordered well

struct StripIconButton: View {
    @Environment(\.theme) private var theme
    let icon: String
    let label: String
    var size: CGFloat = 32
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(AppFont.glyph(size * 0.4, .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.palette.isDark ? theme.palette.bgBase : theme.palette.bgRaised))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.palette.borderDefault, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
