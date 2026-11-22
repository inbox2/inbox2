import SwiftUI

/// The time zone the calendar grid shows, after desktop's `TimeZonePicker`
/// (`ui/web/src/components/Calendar/TimeZonePicker.jsx`): a traveller keeps
/// meetings in home time, or plans in a colleague's. nil = this device's zone.
/// The week and day grids, the month and the mini month all read `calendar`.
@MainActor final class CalendarZone: ObservableObject {
    static let shared = CalendarZone()
    private static let key = "calendar.displayTimeZone"

    @Published var identifier: String? {
        didSet {
            UserDefaults.standard.set(identifier, forKey: Self.key)
            Self.applyToFormatters(timeZone)
        }
    }

    private init() {
        identifier = UserDefaults.standard.string(forKey: Self.key).flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
        Self.applyToFormatters(timeZone)
        // "This iPad's time" follows the iPad when its zone changes with the app open.
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in
                let zone = CalendarZone.shared
                Self.applyToFormatters(zone.timeZone)
                zone.objectWillChange.send()
            }
        }
    }

    /// Event and zone times on the calendar print through `ZoneStore.clock`.
    private static func applyToFormatters(_ tz: TimeZone) { CalendarClock.formatter.timeZone = tz }

    /// The picker's list is open (the sidebar button, or the command palette).
    @Published var pickerOpen = false

    var timeZone: TimeZone { identifier.flatMap(TimeZone.init(identifier:)) ?? .current }
    var isOverridden: Bool { identifier != nil && timeZone.identifier != TimeZone.current.identifier }

    /// Calendar.current with the shown zone.
    var calendar: Calendar {
        var c = Calendar.current
        c.timeZone = timeZone
        return c
    }

    /// The day an event shows on in this zone. An all-day event keeps its date: its
    /// midnights are this device's, so the date moves across, not the instant.
    func day(of e: CalendarEvent) -> Date {
        if e.allDay { return moved(e.dayKey) }
        return calendar.startOfDay(for: e.start ?? e.dayKey)
    }

    /// Whether the event still shows from `today` on (an all-day span by its exclusive end date).
    func isCurrent(_ e: CalendarEvent, from today: Date) -> Bool {
        if e.allDay { return day(of: e) >= today || (e.end.map(moved) ?? .distantPast) > today }
        return (e.end ?? e.start ?? .distantFuture) >= today
    }

    /// Whether an all-day event covers the shown-zone day starting at `dayStart`,
    /// by its dates (start date ≤ day < exclusive end date).
    func allDayCovers(_ e: CalendarEvent, _ dayStart: Date) -> Bool {
        let s = day(of: e)
        let end = e.end.map(moved) ?? calendar.date(byAdding: .day, value: 1, to: s) ?? s
        return s <= dayStart && dayStart < max(end, calendar.date(byAdding: .day, value: 1, to: s) ?? end)
    }

    /// A device-zone wall-clock date, read as the same wall clock in this zone.
    func moved(_ d: Date) -> Date {
        calendar.date(from: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)) ?? d
    }

    // ── Labels ──

    /// "Tokyo" from "Asia/Tokyo", "Sao Paulo" from "America/Sao_Paulo".
    static func city(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    /// "GMT+9" / "CET" for now in that zone.
    static func abbreviation(_ tz: TimeZone) -> String { tz.abbreviation() ?? "GMT" }

    /// Winter and summer abbreviations ("pst", "pdt"), so either finds the zone all year.
    private static func abbreviations(_ id: String) -> Set<String> {
        guard let tz = TimeZone(identifier: id) else { return [] }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let dates = [1, 7].compactMap { DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: tz, year: year, month: $0, day: 15).date }
        return Set(dates.compactMap { tz.abbreviation(for: $0)?.lowercased() })
    }

    /// Zones whose city, region or abbreviation matches, cities first.
    static func search(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        guard !q.isEmpty else { return all.sorted { city($0) < city($1) } }
        func score(_ id: String) -> Int? {
            let c = city(id).lowercased()
            if c.hasPrefix(q) { return 0 }
            if c.contains(q) { return 1 }
            if id.lowercased().contains(q) { return 2 }
            if abbreviations(id).contains(q) { return 3 }
            return nil
        }
        return all.compactMap { id in score(id).map { (id, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : city($0.0) < city($1.0) }
            .map(\.0)
    }
}

/// The picker button + sheet, for the iPad calendar sidebar.
struct CalendarTimeZonePicker: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var zone = CalendarZone.shared
    @State private var query = ""
    private var p: ThemePalette { theme.palette }

    var body: some View {
        Button { zone.pickerOpen = true } label: {
            HStack(spacing: Space.s2) {
                Image(systemName: "globe").font(AppFont.xs(.semibold))
                    .foregroundStyle(zone.isOverridden ? p.accentViolet : p.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(zone.isOverridden ? CalendarZone.city(zone.timeZone.identifier) : "This iPad's time")
                        .font(AppFont.sm(.semibold)).foregroundStyle(p.textPrimary).lineLimit(1)
                    Text(CalendarZone.abbreviation(zone.timeZone))
                        .font(AppFont.xs3).foregroundStyle(p.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(AppFont.xs3).foregroundStyle(p.textTertiary)
            }
            .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calendar time zone")
        // A fresh search each time it opens (the sidebar button or the palette).
        .onChange(of: zone.pickerOpen, initial: true) { _, open in if open { query = "" } }
        .popover(isPresented: $zone.pickerOpen) { list.frame(minWidth: 320, minHeight: 420) }
    }

    private var list: some View {
        NavigationStack {
            List {
                if zone.isOverridden {
                    Button { zone.identifier = nil; zone.pickerOpen = false } label: {
                        Label("Use this iPad's time (\(CalendarZone.abbreviation(.current)))", systemImage: "location")
                    }
                }
                ForEach(CalendarZone.search(query).prefix(200), id: \.self) { id in
                    // Picking this iPad's own zone means "follow the iPad", so travel still moves it.
                    Button { zone.identifier = id == TimeZone.current.identifier ? nil : id; zone.pickerOpen = false } label: { row(id) }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "City or zone")
            .navigationTitle("Time zone")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ id: String) -> some View {
        let tz = TimeZone(identifier: id) ?? .current
        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(CalendarZone.city(id)).font(AppFont.sm).foregroundStyle(p.textPrimary)
                Text(id).font(AppFont.xs3).foregroundStyle(p.textTertiary)
            }
            Spacer()
            Text(CalendarZone.abbreviation(tz)).font(AppFont.xs).monospacedDigit().foregroundStyle(p.textSecondary)
            if tz.identifier == zone.timeZone.identifier && zone.isOverridden {
                Image(systemName: "checkmark").font(AppFont.xs(.semibold)).foregroundStyle(p.accentViolet)
            }
        }
    }
}
