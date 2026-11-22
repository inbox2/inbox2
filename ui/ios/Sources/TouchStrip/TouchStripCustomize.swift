import SwiftUI

/// "Customize Touch Strip" (port of `StripCustomize.jsx`): a palette of widgets,
/// each showing its real compact key with live data and an on/off switch; the
/// strip's order (drag to reorder); and the selected widget's settings. Every
/// edit applies at once and goes to the account (TouchStripModel.update).
struct TouchStripCustomize: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = TouchStripModel.shared
    @State private var selected: StripWidget = .clocks

    private var p: ThemePalette { theme.palette }
    private var config: StripConfig { model.config }

    var body: some View {
        NavigationStack {
            // Side by side when there is room; stacked in a narrow window (Split View).
            GeometryReader { geo in
                if geo.size.width >= 700 {
                    HStack(alignment: .top, spacing: 0) {
                        tiles.frame(width: min(400, geo.size.width * 0.45))
                        Rectangle().fill(p.borderSubtle).frame(width: 1)
                        settingsList
                    }
                } else {
                    VStack(spacing: 0) {
                        tiles.frame(height: geo.size.height * 0.45)
                        Rectangle().fill(p.borderSubtle).frame(height: 1)
                        settingsList
                    }
                }
            }
            .background(p.bgBase)
            .navigationTitle("Customize Touch Strip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Restore defaults") { model.reset() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationSizing(.page)
    }

    // MARK: Palette

    private var tiles: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Switch widgets on or off. Tap a widget to change its settings. Drag the rows in Order to change the order. Your account keeps this layout for all your devices.")
                    .font(AppFont.xs2).foregroundStyle(p.textSecondary)
                ForEach(StripWidget.allCases) { tile($0) }
            }
            .padding(16)
        }
    }

    private var settingsList: some View {
        List {
            orderSection
            settings
        }
        .environment(\.editMode, .constant(.active))
    }

    private func tile(_ id: StripWidget) -> some View {
        let on = config.items.contains(id)
        let isSelected = selected == id
        return VStack(alignment: .leading, spacing: 0) {
            // The real key with live data — look, don't touch.
            HStack(spacing: 0) { StripWidgetView(id: id, config: config, interactive: false) }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                // A fixed height, the key centred in it: stretching to the grid row
                // left the key stuck to the top with a gap below.
                .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64, alignment: .leading)
                .clipped()
                .background(StripBackground())
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(on ? 1 : 0.45)
            HStack(spacing: 10) {
                Image(systemName: id.icon)
                    .font(AppFont.glyph(14))
                    .foregroundStyle(p.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(p.bgRaised))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.borderDefault, lineWidth: 1))
                VStack(alignment: .leading, spacing: 1) {
                    Text(id.label).font(AppFont.sm(.semibold)).foregroundStyle(p.textPrimary)
                    Text(id.hint).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                }
                Spacer(minLength: 8)
                Toggle("Show \(id.label) in the strip", isOn: Binding(get: { on }, set: { _ in toggle(id) }))
                    .labelsHidden()
                    .tint(p.toggle)
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(p.bgPanel))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? p.toggle : p.borderDefault, lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selected = id }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "\(id.label) settings") { selected = id }
    }

    private func toggle(_ id: StripWidget) {
        model.update { c in
            if let i = c.items.firstIndex(of: id) { c.items.remove(at: i) } else { c.items.append(id) }
        }
    }

    // MARK: Order

    private var orderSection: some View {
        Section("Order") {
            ForEach(config.items) { id in
                Button { selected = id } label: {
                    Label(id.label, systemImage: id.icon).foregroundStyle(selected == id ? p.toggle : p.textPrimary)
                }
            }
            .onMove { from, to in model.update { $0.items.move(fromOffsets: from, toOffset: to) } }
            .onDelete { offsets in model.update { $0.items.remove(atOffsets: offsets) } }
            if config.items.isEmpty {
                Text("The strip is empty.").foregroundStyle(p.textTertiary)
            }
        }
    }

    // MARK: Per-widget settings

    @ViewBuilder private var settings: some View {
        switch selected {
        case .clocks: ClockSettings(model: model)
        case .weather: WeatherSettings(model: model)
        case .stocks: StockSettings(model: model)
        case .crypto: CryptoSettings(model: model)
        case .news: NewsSettings(model: model)
        case .ip:
            Section("Public IP") {
                Text("Shows the public IP address that the inbox2 API sees, with the country and the ISP. It flags VPN and proxy exits. Tap the key to copy the address.")
                    .font(AppFont.xs).foregroundStyle(p.textSecondary)
            }
        }
    }
}

// MARK: - Editors

/// A binding to one field of one row; ignores writes after the row went away.
@MainActor private func rowBinding<T>(_ model: TouchStripModel, _ path: WritableKeyPath<StripConfig, [T]>, _ i: Int,
                                      get: @escaping (T) -> String, set: @escaping (inout T, String) -> Void) -> Binding<String> {
    Binding(
        get: { i < model.config[keyPath: path].count ? get(model.config[keyPath: path][i]) : "" },
        set: { v in model.update { c in if i < c[keyPath: path].count { set(&c[keyPath: path][i], v) } } }
    )
}

private func describePlace(_ p: StripPlaceMatch) -> String { [p.name, p.region, p.country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }

private struct ClockSettings: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: TouchStripModel

    var body: some View {
        let clocks = model.config.clocks
        let base = localTimeZone()
        let now = Date()
        Section {
            ForEach(Array(clocks.enumerated()), id: \.offset) { i, c in
                HStack(spacing: 10) {
                    TextField("Label", text: rowBinding(model, \.clocks, i, get: { $0.label }, set: { $0.label = String($1.uppercased().prefix(4)) }))
                        .font(AppFont.mono(13, .semibold))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .frame(width: 56)
                    Text(c.tz.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? c.tz)
                        .foregroundStyle(theme.palette.textPrimary)
                    Spacer()
                    let off = relativeOffset(c.tz, base, now)
                    Text(formatMinutes(minutesInZone(c.tz, now)) + (off.isEmpty ? "" : " · \(off)"))
                        .font(AppFont.xs).monospacedDigit().foregroundStyle(theme.palette.textTertiary)
                }
            }
            .onDelete { o in model.update { $0.clocks.remove(atOffsets: o) } }
            .onMove { f, t in model.update { $0.clocks.move(fromOffsets: f, toOffset: t) } }
            SearchAdd(placeholder: "Add a city…", disabled: clocks.count >= stripLimit(.clocks),
                      search: StripAPI.places, describe: describePlace) { place in
                guard let tz = place.timezone else { return }
                model.update { c in
                    let row = StripClock(label: shortLabel(place.name), tz: tz)
                    if c.clocks.count < stripLimit(.clocks), !c.clocks.contains(row) { c.clocks.append(row) }
                }
            }
        } header: {
            Text("World clocks")
        } footer: {
            Text("Tap the clocks key for a meeting planner. It shows each city's 09:00–17:00 on your day, and when you all overlap.")
        }
    }
}

private struct WeatherSettings: View {
    @ObservedObject var model: TouchStripModel

    var body: some View {
        let places = model.config.places
        let here = places.contains { $0.isCurrent }
        let named = places.indices.filter { !places[$0].isCurrent }
        Section {
            Toggle("Show the weather where you are (from your IP address)", isOn: Binding(get: { here }, set: { on in
                model.update { c in
                    c.places = on ? Array(([StripPlace.here] + c.places.filter { !$0.isCurrent }).prefix(stripLimit(.places)))
                                  : c.places.filter { !$0.isCurrent }
                }
            }))
            ForEach(named, id: \.self) { i in Text(places[i].label ?? "") }
                .onDelete { o in
                    let drop = Set(o.map { named[$0] })
                    model.update { c in c.places = c.places.enumerated().filter { !drop.contains($0.offset) }.map(\.element) }
                }
            SearchAdd(placeholder: "Add a city…", disabled: places.count >= stripLimit(.places),
                      search: StripAPI.places, describe: describePlace) { place in
                model.update { c in
                    let row = StripPlace(label: place.name, lat: place.lat, lon: place.lon)
                    if c.places.count < stripLimit(.places), !c.places.contains(where: { $0.lat == row.lat && $0.lon == row.lon }) { c.places.append(row) }
                }
            }
        } header: {
            Text("Weather")
        } footer: {
            Text("The first place gets the full key. The others show their temperature beside it.")
        }
    }
}

private struct StockSettings: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: TouchStripModel

    var body: some View {
        let stocks = model.config.stocks
        let byWeight = model.config.options.stock_size == .weight
        Section {
            ForEach(Array(stocks.enumerated()), id: \.offset) { i, s in
                HStack {
                    Text(s.symbol).font(AppFont.mono(13, .semibold)).foregroundStyle(theme.palette.textPrimary)
                    Spacer()
                    if byWeight {
                        TextField("Weight", value: Binding(
                            get: { i < model.config.stocks.count ? model.config.stocks[i].weight : 1 },
                            set: { v in model.update { c in if i < c.stocks.count { c.stocks[i].weight = max(v, 0.1) } } }
                        ), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .accessibilityLabel("Weight for \(s.symbol)")
                    }
                }
            }
            .onDelete { o in model.update { $0.stocks.remove(atOffsets: o) } }
            .onMove { f, t in model.update { $0.stocks.move(fromOffsets: f, toOffset: t) } }
            SearchAdd(placeholder: "Add a ticker: ASML, ^AEX, VWRL.AS…", disabled: stocks.count >= stripLimit(.stocks),
                      search: StripAPI.symbols,
                      describe: { m in [m.symbol, m.name, m.exchange].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }) { m in
                model.update { c in
                    if c.stocks.count < stripLimit(.stocks), !c.stocks.contains(where: { $0.symbol == m.symbol }) { c.stocks.append(StripStock(symbol: m.symbol)) }
                }
            }
            Picker("Tile size", selection: Binding(get: { model.config.options.stock_size }, set: { v in model.update { $0.options.stock_size = v } })) {
                Text("Equal").tag(StockSize.equal)
                Text("My weights").tag(StockSize.weight)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Stocks")
        } footer: {
            Text("The colour of a tile shows today's change. Quotes are delayed and refresh every minute.")
        }
    }
}

private struct CryptoSettings: View {
    @ObservedObject var model: TouchStripModel
    @State private var symbol = ""

    var body: some View {
        Section("Crypto") {
            ForEach(model.config.crypto, id: \.self) { Text($0).font(AppFont.mono(13, .semibold)) }
                .onDelete { o in model.update { $0.crypto.remove(atOffsets: o) } }
                .onMove { f, t in model.update { $0.crypto.move(fromOffsets: f, toOffset: t) } }
            HStack {
                TextField("Add a coin: BTC, ETH, SOL…", text: $symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(symbol.trimmingCharacters(in: .whitespaces).isEmpty || model.config.crypto.count >= stripLimit(.crypto))
            }
            Picker("Currency", selection: Binding(get: { model.config.options.crypto_currency }, set: { v in model.update { $0.options.crypto_currency = v } })) {
                ForEach(cryptoCurrencies, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func add() {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        if s.range(of: "^[A-Z0-9]{2,10}$", options: .regularExpression) != nil {
            model.update { c in if !c.crypto.contains(s), c.crypto.count < stripLimit(.crypto) { c.crypto.append(s) } }
        }
        symbol = ""
    }
}

private struct NewsSettings: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: TouchStripModel
    @State private var url = ""
    @State private var label = ""

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool {
        trimmedURL.range(of: "^https?://\\S+$", options: [.regularExpression, .caseInsensitive]) != nil && URL(string: trimmedURL)?.host != nil
    }

    var body: some View {
        let feeds = model.config.feeds
        Section {
            ForEach(Array(feeds.enumerated()), id: \.offset) { i, f in
                HStack(spacing: 10) {
                    TextField("Label", text: rowBinding(model, \.feeds, i, get: { $0.label }, set: { $0.label = String($1.prefix(12)) }))
                        .autocorrectionDisabled()
                        .frame(width: 90)
                    Text(f.url.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .onDelete { o in model.update { $0.feeds.remove(atOffsets: o) } }
            .onMove { f, t in model.update { $0.feeds.move(fromOffsets: f, toOffset: t) } }
            HStack(spacing: 10) {
                TextField("Label", text: $label).autocorrectionDisabled().frame(width: 90)
                TextField("RSS or Atom feed URL", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Button("Add", action: add).disabled(!valid || feeds.count >= stripLimit(.feeds))
            }
        } header: {
            Text("News")
        }
    }

    private func add() {
        guard valid, let host = URL(string: trimmedURL)?.host else { return }
        let fallback = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let row = StripFeed(url: trimmedURL, label: String((label.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : label.trimmingCharacters(in: .whitespaces)).prefix(12)))
        model.update { c in
            if c.feeds.count < stripLimit(.feeds), !c.feeds.contains(where: { $0.url == row.url }) { c.feeds.append(row) }
        }
        url = ""; label = ""
    }
}

/// Type-ahead rows that add the picked result (250ms debounce).
private struct SearchAdd<R: Hashable>: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    let disabled: Bool
    let search: (String) async throws -> [R]
    let describe: (R) -> String
    let onPick: (R) -> Void
    @State private var query = ""
    @State private var results: [R] = []

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(AppFont.xs2).foregroundStyle(theme.palette.textTertiary)
            TextField(disabled ? "The list is full" : placeholder, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(disabled)
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = (try? await search(q)) ?? []
            if !Task.isCancelled { results = found }
        }
        ForEach(results, id: \.self) { r in
            Button {
                onPick(r)
                query = ""
                results = []
            } label: {
                Label(describe(r), systemImage: "plus.circle").foregroundStyle(theme.palette.textPrimary)
            }
        }
    }
}
