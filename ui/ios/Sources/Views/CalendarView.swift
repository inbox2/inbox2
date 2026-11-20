import SwiftUI

/// Local-offset ISO8601 (internet date-time) — shared by the agenda range queries
/// and the event-sheet write-back so they emit the identical wall-clock format.
let isoLocalInternet: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
    return f
}()

/// Calendar view mode — an "Upcoming" agenda list, a "Day" timeline, a "Week"
/// grid (iPad only) or a "Calendar" month grid (the single source for the
/// segmented control's labels).
enum CalMode: String, CaseIterable, Identifiable {
    case agenda = "Upcoming"
    case day = "Day"
    case week = "Week"
    case month = "Calendar"
    var id: String { rawValue }
}

/// Calendar — events read live from the local store (`calendar_events` joined to
/// `calendars`). Two modes: an **Agenda** of upcoming events grouped by day, and a
/// **Month** grid with per-day event dots that drives a day-detail list. Tapping an
/// event opens a detail sheet. Mirrors the desktop calendar's data, native iOS UI.
struct CalendarView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var chrome: ChromeModel
    @EnvironmentObject private var cloud: CloudSession
    /// iPad (regular width) adds the desktop week grid and opens on it.
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ObservedObject private var zoneStore = ZoneStore.shared
    @ObservedObject private var blockStore = BlockedTimeStore.shared
    /// A tapped blocked window awaiting "Remove blocked time?".
    @State private var pendingBlockRemove: CloudBlockedTime?
    @State private var events: [CalendarEvent] = []          // agenda: upcoming
    @State private var chartEvents: [CalendarEvent] = []     // load chart: ±30 days
    @State private var selectedChartDay: Date?               // tapped chart bar → list filter
    @State private var visibleCount = 15                     // agenda rows rendered (grows on scroll)
    private let pageSize = 15
    @State private var monthEvents: [CalendarEvent] = []     // month: visible-month window
    @State private var monthMap: [Date: [CalendarEvent]] = [:] // day → events (precomputed off-main)
    @State private var selected: CalendarEvent?
    /// A failed tap-and-hold quick action (delete / RSVP) — surfaced in an alert.
    @State private var actionError: String?
    /// A long-pressed invite awaiting "decline to the organizer, or just delete?".
    @State private var pendingInviteDelete: CalendarEvent?
    @State private var showNewEvent = false
    @State private var showCreateChoice = false   // "+" → New event / New zone
    /// The chooser's pick, run in its onDismiss so the next sheet opens after it closes.
    @State private var pendingCreate: CreateKind?
    @State private var showNewZone = false
    @State private var editingZone: CloudZone?
    /// A range picked on the day timeline — pre-fills the new event/zone sheet.
    /// nil = the "+" defaults.
    @State private var createRange: Range<Date>?
    @State private var hasWritableCalendars = false   // gates "+"; loaded off-main, not queried in body
    @State private var mode: CalMode = .agenda
    @State private var padModeSet = false
    @State private var monthAnchor = Calendar.current.startOfDay(for: Date())  // any day in the visible month
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())
    private var p: ThemePalette { theme.palette }
    private let cal = Calendar.current
    private var isPad: Bool { sizeClass == .regular }

    /// Connected channels in switcher order — drives each channel's deterministic
    /// calendar colour (first channel = electric blue).
    private var channelOrder: [String] { engine.accounts.map(\.id) }

    private var grouped: [(day: Date, items: [CalendarEvent])] {
        // Today's ended meetings stay listed, faded (the row's isPast opacity) — as
        // Google Calendar and Outlook do. Hiding them made an event saved for earlier
        // today vanish the moment the sheet closed, as if the save had gone nowhere.
        var byDay = Dictionary(grouping: events, by: \.dayKey)
        // Zone-only days still get a section, so a focus block with no meetings in
        // it shows up in the agenda too.
        let today = cal.startOfDay(for: Date())
        for z in zoneStore.zones.values where z.end > today {
            let day = cal.startOfDay(for: max(z.start, today))
            if byDay[day] == nil { byDay[day] = [] }
        }
        return byDay
            .map { (day: $0.key, items: $0.value.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }) }
            .sorted { $0.day < $1.day }
    }

    /// Agenda sections: the full upcoming grouping, or — when a chart bar is tapped —
    /// just that day's meetings (drawn from the wider ±30-day chart window so past
    /// days work too).
    private var agendaSections: [(day: Date, items: [CalendarEvent])] {
        guard let sel = selectedChartDay else { return grouped }
        let items = chartEvents
            .filter { cal.isDate($0.dayKey, inSameDayAs: sel) }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        return [(day: sel, items: items)]
    }

    /// Total events across all sections (the full list size).
    private var totalAgendaCount: Int { agendaSections.reduce(0) { $0 + $1.items.count } }

    /// `agendaSections` truncated to the first `visibleCount` events (headers kept),
    /// so we only build a window of rows and grow it as the user scrolls.
    private var visibleSections: [(day: Date, items: [CalendarEvent])] {
        var remaining = visibleCount
        var out: [(day: Date, items: [CalendarEvent])] = []
        for sec in agendaSections {
            if remaining <= 0 { break }
            let take = Array(sec.items.prefix(remaining))
            out.append((day: sec.day, items: take))
            remaining -= take.count
        }
        return out
    }

    // The body is split in three (screen → sheets → tasks): as one expression
    // Xcode 26's type checker gives up on it ("unable to type-check this
    // expression in reasonable time"), which fails the CI archive.
    var body: some View {
        NavigationStack {
            screenWithSheets
            .task(id: engine.dataVersion) { await reloadAgenda() }
            .task(id: engine.dataVersion) { await reloadChart() }
            .task(id: engine.dataVersion) {
                hasWritableCalendars = await engine.store.read { !$0.writableCalendars().isEmpty }
            }
            .task(id: monthReloadKey) { await reloadMonth() }
            // Zones come from the API, not the store — no dataVersion here, it bumps on
            // every mark-read. The app refreshes the near window on each foreground.
            .task(id: cloud.isSignedIn) {
                let today = cal.startOfDay(for: Date())
                await zoneStore.load(from: today.addingTimeInterval(-30 * 86_400),
                                     to: today.addingTimeInterval(90 * 86_400))
                zoneStore.reconcileAnchors(events + chartEvents)
            }
            .task(id: "\(cloud.isSignedIn)|\(monthStart.timeIntervalSince1970)") {
                guard let from = gridDays.first, let last = gridDays.last else { return }
                await zoneStore.load(from: from, to: last.addingTimeInterval(86_400))
                zoneStore.reconcileAnchors(monthEvents)
            }
            .task(id: chrome.pendingCalendarEventKey) { await openPendingInviteEvent() }
            .onChange(of: selectedChartDay) { visibleCount = pageSize }
            .onChange(of: events.count) { visibleCount = pageSize }
            // Paging days on the timeline keeps the month grid on the same month.
            .onChange(of: selectedDay) { if mode == .day || mode == .week { monthAnchor = selectedDay } }
        }
    }

    private var screen: some View {
        VStack(spacing: 0) {
            ScreenHeader("Calendar") {
                // iPad: the mode switch rides in the title bar to save a row.
                if isPad { modeTabs.frame(maxWidth: 340) }
                IconButton("plus", tint: p.accentViolet) {
                    createRange = nil
                    if zoneStore.enabled { showCreateChoice = true } else { showNewEvent = true }
                }
                .disabled(!hasWritableCalendars && !zoneStore.enabled)
            }
            if !isPad {
                modeTabs
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s2)
            }

            switch mode {
            case .agenda: agendaBody
            case .day:
                CalendarDayView(day: $selectedDay, channelOrder: channelOrder,
                                highlight: showCreateChoice ? createRange : nil,
                                onSelect: { selected = $0 }, onEditZone: { editingZone = $0 },
                                onSelectBlock: { pendingBlockRemove = $0 },
                                onCreate: { range in
                                    guard hasWritableCalendars || zoneStore.enabled else { return }
                                    createRange = range
                                    showCreateChoice = true
                                })
            case .week:
                CalendarWeekView(day: $selectedDay, channelOrder: channelOrder,
                                 highlight: showCreateChoice ? createRange : nil,
                                 onSelect: { selected = $0 }, onEditZone: { editingZone = $0 },
                                 onSelectBlock: { pendingBlockRemove = $0 },
                                 onCreate: { range in
                                     guard hasWritableCalendars || zoneStore.enabled else { return }
                                     createRange = range
                                     showCreateChoice = true
                                 },
                                 onOpenDay: { d in
                                     selectedDay = d
                                     withAnimation(.easeOut(duration: 0.15)) { mode = .day }
                                 })
            case .month: monthBody
            }
        }
        .pageBackground()
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: isPad ? 0 : 70) }
        .onAppear { if isPad && !padModeSet { padModeSet = true; mode = .week } }
        // iPad sidebar: a mini-month pick jumps the grid to that day…
        .onChange(of: chrome.calendarJump) { _, d in
            guard let d else { return }
            chrome.calendarJump = nil
            selectedDay = cal.startOfDay(for: d)
            monthAnchor = d
            if mode == .agenda { mode = isPad ? .week : .day }
        }
        // …and its New event runs the same create flow as "+".
        .onChange(of: chrome.calendarCreateTick) {
            guard hasWritableCalendars || zoneStore.enabled else { return }
            createRange = nil
            if zoneStore.enabled { showCreateChoice = true } else { showNewEvent = true }
        }
        .onChange(of: selectedDay, initial: true) { chrome.calendarDay = selectedDay }
        // The sidebar's New event greys out exactly when "+" does.
        .onChange(of: hasWritableCalendars || zoneStore.enabled, initial: true) { _, can in chrome.calendarCanCreate = can }
    }

    private var screenWithSheets: some View {
        screen
        .sheet(item: $selected) { EventDetailSheet(event: $0) }
        .sheet(isPresented: $showNewEvent) {
            NewEventSheet(initialDay: createDay, initialStart: createRange?.lowerBound,
                          initialEnd: createRange?.upperBound)
        }
        .sheet(isPresented: $showCreateChoice, onDismiss: runPendingCreate) {
            CreateChoiceSheet(
                range: createRange,
                kinds: [hasWritableCalendars ? .event : nil,
                        zoneStore.enabled ? .zone : nil,
                        // Drag ranges only ("+" has no range) — created at once, no sheet.
                        blockStore.enabled && createRange != nil ? .block : nil].compactMap { $0 },
                onPick: { pendingCreate = $0; showCreateChoice = false })
        }
        .sheet(isPresented: $showNewZone) {
            ZoneSheet(initialDay: createDay, initialStart: createRange?.lowerBound, initialEnd: createRange?.upperBound)
        }
        .sheet(item: $editingZone) { ZoneSheet(initialDay: $0.start, editing: $0) }
        .confirmationDialog("Delete this event?", isPresented: Binding(
            get: { pendingInviteDelete != nil }, set: { if !$0 { pendingInviteDelete = nil } }
        ), titleVisibility: .visible, presenting: pendingInviteDelete) { ev in
            Button("Decline & delete", role: .destructive) { runDelete(ev, decline: true) }
            Button("Delete only") { runDelete(ev, decline: false) }
            Button("Cancel", role: .cancel) {}
        } message: { ev in
            Text("Let \(ev.organizerLabel ?? "the organizer") know you won't attend?")
        }
        .confirmationDialog("Remove blocked time?", isPresented: Binding(
            get: { pendingBlockRemove != nil }, set: { if !$0 { pendingBlockRemove = nil } }
        ), titleVisibility: .visible, presenting: pendingBlockRemove) { b in
            Button("Remove", role: .destructive) {
                Task { if let err = await blockStore.delete(b) { actionError = err } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("People can book this time again.")
        }
        .alert("Couldn't update event", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    /// Phone: Upcoming / Day / Calendar. iPad: Upcoming / Day / Week — its month is
    /// the sidebar's mini month.
    private var modeTabs: some View {
        SegmentedTabs(
            selection: Binding(
                get: { mode.rawValue },
                set: { if let m = CalMode(rawValue: $0) { withAnimation(.easeOut(duration: 0.15)) { mode = m } } }
            ),
            options: CalMode.allCases.filter { isPad ? $0 != .month : $0 != .week }.map(\.rawValue)
        )
    }

    /// Runs the chooser's pick once its sheet is gone (two sheets can't overlap).
    private func runPendingCreate() {
        guard let kind = pendingCreate else { return }
        pendingCreate = nil
        switch kind {
        case .event: showNewEvent = true
        case .zone: showNewZone = true
        case .block:
            guard let r = createRange else { return }
            Task { if let err = await blockStore.create(r) { actionError = err } }
        }
    }

    // ── Agenda mode ──

    /// The day a new event/zone defaults to — the one the user is looking at.
    private var createDay: Date { mode == .agenda ? (selectedChartDay ?? Date()) : selectedDay }

    @ViewBuilder private var agendaBody: some View {
        if events.isEmpty && grouped.isEmpty {
            EmptyState(systemImage: "calendar", title: "No upcoming events",
                       message: "Events from your connected calendars show up here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // One page scroll: the load chart scrolls away with the list. The chart's
            // bar colours match each row's strip; tapping a bar filters to that day.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    UpcomingLoadChart(events: chartEvents, channelOrder: channelOrder,
                                      selectedDay: selectedChartDay) { day in
                        withAnimation(.easeOut(duration: 0.15)) {
                            if let s = selectedChartDay, cal.isDate(s, inSameDayAs: day) {
                                selectedChartDay = nil
                            } else {
                                selectedChartDay = day
                            }
                        }
                    }
                    .grooveFramed()
                    .padding(.bottom, Space.s2)

                    // Rows render lazily as you scroll; the card wraps the whole stack
                    // so it stays one pane.
                    LazyVStack(alignment: .leading, spacing: 0) { agendaList }
                        .padding(.bottom, Space.s3)
                        .insetCard()
                }
                .padding(.top, Space.s1)
            }
        }
    }

    @ViewBuilder private var agendaList: some View {
        ForEach(Array(visibleSections.enumerated()), id: \.element.day) { sIdx, section in
            Text(DayHeader.label(section.day))
                .font(AppFont.section(13))
                .foregroundStyle(p.textSecondary)
                .padding(.horizontal, Space.s3)
                .padding(.top, sIdx == 0 ? Space.s3 : Space.s4)
                .padding(.bottom, Space.s1)
            if section.items.isEmpty && zoneStore.zones(on: section.day).isEmpty {
                VStack(spacing: Space.s2) {
                    GradientGlyph(systemImage: "calendar", size: 52)
                        .frame(height: 72)
                    Text("No meetings").font(AppFont.sm).foregroundStyle(p.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Space.s4)
            }
            dayRows(section.day, section.items, rowPadding: Space.s2 + 2)
        }
        // Load-more sentinel: when it scrolls into view, grow the window.
        if visibleCount < totalAgendaCount {
            HStack { Spacer(); ProgressView().tint(p.textTertiary); Spacer() }
                .padding(.vertical, Space.s3)
                .onAppear { visibleCount += pageSize }
        }
    }

    /// A meeting-invite banner tap set `chrome.pendingCalendarEventKey`; open that
    /// event's detail (and anchor the month/day to it), then clear the signal.
    private func openPendingInviteEvent() async {
        guard let key = chrome.pendingCalendarEventKey else { return }
        let event = await engine.store.read { $0.event(byKey: key) }
        await MainActor.run {
            chrome.pendingCalendarEventKey = nil
            guard let event else { return }
            if let start = event.start {
                selectedDay = cal.startOfDay(for: start)
                monthAnchor = start
            }
            selected = event
        }
    }

    private func reloadAgenda() async {
        let from = isoLocalInternet.string(from: cal.startOfDay(for: Date()))
        let result = await engine.store.read { $0.upcomingEvents(fromISO: from) }
        guard !Task.isCancelled else { return }
        events = result
        zoneStore.reconcileAnchors(result)
    }

    /// Load the ±30-day window that feeds the scrollable load chart.
    private func reloadChart() async {
        let today = cal.startOfDay(for: Date())
        let from = cal.date(byAdding: .day, value: -30, to: today) ?? today
        let to = cal.date(byAdding: .day, value: 31, to: today) ?? today
        let fromISO = isoLocalInternet.string(from: from), toISO = isoLocalInternet.string(from: to)
        let result = await engine.store.read { $0.eventsBetween(fromISO: fromISO, toISO: toISO) }
        guard !Task.isCancelled else { return }
        chartEvents = result
        zoneStore.reconcileAnchors(result)
    }

    // ── Month mode ──

    /// Re-query the month window whenever the visible month or engine data changes.
    private var monthReloadKey: String { "\(monthStart.timeIntervalSince1970)|\(engine.dataVersion)" }

    /// First day of the visible month.
    private var monthStart: Date {
        cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor)) ?? monthAnchor
    }

    /// The 42 day-cells (6 weeks) covering the visible month, starting on the
    /// locale's first weekday on/before the 1st.
    private var gridDays: [Date] {
        let firstWeekday = cal.firstWeekday
        let weekdayOf1st = cal.component(.weekday, from: monthStart)
        let lead = (weekdayOf1st - firstWeekday + 7) % 7
        let start = cal.date(byAdding: .day, value: -lead, to: monthStart) ?? monthStart
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func reloadMonth() async {
        guard let from = gridDays.first,
              let to = cal.date(byAdding: .day, value: 1, to: gridDays.last ?? from) else { return }
        let fromISO = isoLocalInternet.string(from: from), toISO = isoLocalInternet.string(from: to)
        // Fetch + build the day→events map off the main thread; the grid then does
        // O(1) lookups per cell instead of filtering all events 42 times.
        let (result, map) = await engine.store.read { store -> ([CalendarEvent], [Date: [CalendarEvent]]) in
            let evs = store.eventsBetween(fromISO: fromISO, toISO: toISO)
            return (evs, Self.buildDayMap(evs))
        }
        guard !Task.isCancelled else { return }
        monthEvents = result
        monthMap = map
        zoneStore.reconcileAnchors(result)
    }

    /// Bucket each event under every day its span covers (multi-day events dot every
    /// day), sorted by start. Built once per month load, off the main thread.
    private nonisolated static func buildDayMap(_ events: [CalendarEvent]) -> [Date: [CalendarEvent]] {
        let cal = Calendar.current
        var map: [Date: [CalendarEvent]] = [:]
        for ev in events {
            let s = ev.start ?? .distantFuture
            let e = ev.end ?? s
            var day = cal.startOfDay(for: s)
            let endDay = cal.startOfDay(for: e)
            var guardN = 0
            while day <= endDay && guardN < 90 {
                let dayEnd = cal.date(byAdding: .day, value: 1, to: day) ?? day
                if s < dayEnd && e >= day { map[day, default: []].append(ev) }
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next; guardN += 1
            }
        }
        for (k, v) in map {
            map[k] = v.sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
        }
        return map
    }

    /// Events covering a given day — O(1) from the precomputed map.
    private func events(on day: Date) -> [CalendarEvent] {
        monthMap[cal.startOfDay(for: day)] ?? []
    }

    private var monthBody: some View {
        ScrollView {
            VStack(spacing: Space.s3) {
                // Same spacing as the outer stack, so other themes lay out unchanged.
                VStack(spacing: Space.s3) {
                    monthHeader
                    weekdayRow
                    monthGrid
                }
                .grooveFramed()
                dayDetail
            }
            .padding(.bottom, Space.s4)
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left").font(AppFont.md(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(p.accentViolet)
            Spacer()
            Text(monthTitle).font(AppFont.title3).foregroundStyle(p.textPrimary)
            Spacer()
            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right").font(AppFont.md(.semibold))
            }
            .buttonStyle(.plain).foregroundStyle(p.accentViolet)
        }
        .overlay(alignment: .trailing) {
            if !cal.isDate(monthAnchor, equalTo: Date(), toGranularity: .month) {
                Button("Today") { goToday() }
                    .font(AppFont.xs(.semibold)).foregroundStyle(p.accentViolet)
                    .buttonStyle(.plain).offset(x: 0, y: 26)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
    }

    private static let monthYear: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private var monthTitle: String { Self.monthYear.string(from: monthStart) }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { sym in
                Text(sym).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Space.s3)
    }

    /// Very-short weekday symbols rotated to the locale's first weekday.
    private var orderedWeekdaySymbols: [String] {
        let syms = cal.veryShortWeekdaySymbols
        let shift = cal.firstWeekday - 1
        return Array(syms[shift...] + syms[..<shift])
    }

    private var monthGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: cols, spacing: 2) {
            ForEach(gridDays, id: \.timeIntervalSince1970) { day in
                dayCell(day)
            }
        }
        .padding(.horizontal, Space.s3)
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = cal.isDate(day, equalTo: monthStart, toGranularity: .month)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let dayEvents = events(on: day)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selectedDay = cal.startOfDay(for: day) }
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(AppFont.sm(isToday ? .bold : .regular))
                    .foregroundStyle(isSelected && p.selectKeycap != nil ? p.keycapLabel(.selected, or: p.textPrimary)
                                     : isToday ? (p.unreadLED ?? p.accentViolet)
                                     : (inMonth ? p.textPrimary : (p.panelRadius != nil ? p.textTertiary : p.textTertiary.opacity(0.5))))
                HStack(spacing: 2) {
                    ForEach(Array(dayEvents.prefix(3).enumerated()), id: \.offset) { _, ev in
                        Circle().fill(colorFor(ev)).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 5)
                // One thin underline per zone category on the day.
                HStack(spacing: 2) {
                    ForEach(zoneKeys(on: day), id: \.self) { key in
                        Capsule().fill(p.zone(key)).frame(width: 10, height: 2)
                    }
                }
                .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background {
                // Groovebox: the selected day is a cream keycap.
                if isSelected, let key = p.selectKeycap {
                    Color.clear.keycap(key, radius: 9)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? p.accentViolet.opacity(0.18) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(isSelected ? p.accentViolet : Color.clear, lineWidth: 1)
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var dayDetail: some View {
        let items = events(on: selectedDay)
        VStack(alignment: .leading, spacing: 0) {
            Text(DayHeader.label(selectedDay))
                .font(AppFont.section(13)).foregroundStyle(p.textSecondary)
                .padding(.horizontal, Space.s3).padding(.top, Space.s3).padding(.bottom, Space.s1)
            if items.isEmpty && zoneStore.zones(on: selectedDay).isEmpty {
                VStack(spacing: Space.s2) {
                    GradientGlyph(systemImage: "calendar", size: 48)
                        .frame(height: 68)
                    Text("No events").font(AppFont.sm).foregroundStyle(p.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, Space.s4)
            } else {
                dayRows(selectedDay, items, rowPadding: 0)
            }
        }
        .padding(.bottom, Space.s2)
        .insetCard()
    }

    // ── Zones in a day list ──

    /// One entry in a day list: a loose event, or a zone wrapping the events that
    /// start inside it.
    private enum DayItem: Identifiable {
        case event(CalendarEvent)
        case zone(CloudZone, [CalendarEvent])
        var id: String {
            switch self { case .event(let e): return "e:" + e.id; case .zone(let z, _): return "z:" + z.id }
        }
        var start: Date {
            switch self { case .event(let e): return e.start ?? .distantPast; case .zone(let z, _): return z.start }
        }
        var isEvent: Bool { if case .event = self { return true }; return false }
    }

    /// Nest each timed event under the first zone its start falls in; zones and
    /// the remaining events then interleave by start time.
    private func dayItems(_ day: Date, _ items: [CalendarEvent]) -> [DayItem] {
        let dayZones = zoneStore.zones(on: day)
        guard !dayZones.isEmpty else { return items.map { .event($0) } }
        var inside: [String: [CalendarEvent]] = [:]
        var loose: [DayItem] = []
        for ev in items {
            if !ev.allDay, let s = ev.start, let z = dayZones.first(where: { s >= $0.start && s < $0.end }) {
                inside[z.id, default: []].append(ev)
            } else {
                loose.append(.event(ev))
            }
        }
        return (loose + dayZones.map { .zone($0, inside[$0.id] ?? []) }).sorted { $0.start < $1.start }
    }

    @ViewBuilder private func dayRows(_ day: Date, _ items: [CalendarEvent], rowPadding: CGFloat) -> some View {
        let list = dayItems(day, items)
        ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
            switch item {
            case .event(let event):
                eventButton(event, hPad: Space.s3, vPad: rowPadding)
            case .zone(let zone, let inner):
                ZoneBlock(zone: zone, onTap: { editingZone = zone }) {
                    ForEach(inner, id: \.id) { eventButton($0, hPad: 0, vPad: 0) }
                }
                .padding(.horizontal, Space.s2)
                .padding(.vertical, Space.s1)
            }
            if item.isEvent && idx < list.count - 1 && list[idx + 1].isEvent {
                Rectangle().fill(p.borderSubtle).frame(height: 1).padding(.leading, Space.s3)
            }
        }
    }

    private func eventButton(_ event: CalendarEvent, hPad: CGFloat, vPad: CGFloat) -> some View {
        Button { selected = event } label: {
            row(event)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Distinct zone-category colour keys on a day (max 3) for the month underline.
    private func zoneKeys(on day: Date) -> [String] {
        let keys = zoneStore.zones(on: day).map { zoneStore.category($0.categoryId)?.color ?? "blue" }
        var seen = Set<String>()
        return Array(keys.filter { seen.insert($0).inserted }.prefix(3))
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = cal.date(byAdding: .month, value: delta, to: monthStart) else { return }
        withAnimation(.easeOut(duration: 0.18)) { monthAnchor = next }
    }

    private func goToday() {
        let today = cal.startOfDay(for: Date())
        withAnimation(.easeOut(duration: 0.18)) { monthAnchor = today; selectedDay = today }
    }

    private func row(_ event: CalendarEvent) -> some View {
        // Groovebox: the event is a solid pastel block with dark ink, no rail.
        let tone = p.eventFill(event)
        let ink = p.eventInk(event)
        return HStack(alignment: .top, spacing: Space.s3) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(event.startTimeLabel)
                    .font(AppFont.xs(.semibold))
                    .foregroundStyle(ink ?? (event.allDay ? p.accentViolet : p.textPrimary))
                if !event.endTimeLabel.isEmpty {
                    Text(event.endTimeLabel).font(AppFont.xs3).foregroundStyle(ink?.opacity(0.7) ?? p.textTertiary)
                }
            }
            .frame(width: 48, alignment: .trailing)

            if tone == nil {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ChannelColor.gradient(for: event.accountKey, in: channelOrder))
                    .frame(width: 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(AppFont.sm).foregroundStyle(ink ?? p.textPrimary).lineLimit(2)
                if let loc = event.location, !loc.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin.and.ellipse").font(AppFont.xs3(.regular))
                        Text(loc).font(AppFont.xs2).lineLimit(1)
                    }
                    .foregroundStyle(ink?.opacity(0.7) ?? p.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, tone == nil ? 0 : Space.s2)
        .padding(.vertical, tone == nil ? 0 : Space.s1)
        .background {
            if let tone {
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(tone)
            }
        }
        .padding(.vertical, Space.s2)
        .contentShape(Rectangle())
        // Meetings that have already ended fade back so the still-relevant ones stand out.
        .opacity(event.isPast && tone == nil ? 0.4 : 1)
        // Tap opens the detail sheet (the wrapping Button); press-and-hold gives the
        // quick actions. Lives on the shared row so both the agenda and the month
        // day-detail list get it.
        .contextMenu { eventMenu(event) }
    }

    /// Press-and-hold quick actions for an event row — mirrors the detail sheet's
    /// actions (open, RSVP for invites, delete) so the common moves skip the sheet.
    @ViewBuilder private func eventMenu(_ event: CalendarEvent) -> some View {
        Button { selected = event } label: { Label("Open", systemImage: "calendar") }
        // RSVP only on someone else's meeting, same gate as the sheet.
        if engine.isInvite(event) {
            Divider()
            Button { quickRsvp(event, "accepted") } label: { Label("Accept", systemImage: "checkmark.circle") }
            Button { quickRsvp(event, "tentative") } label: { Label("Maybe", systemImage: "questionmark.circle") }
            Button { quickRsvp(event, "declined") } label: { Label("Decline", systemImage: "xmark.circle") }
        }
        // Delete only on calendars the user can write to — read-only calendars
        // (shared / subscribed / holidays) 403 on the provider.
        if event.calendarWritable {
            Divider()
            Button(role: .destructive) { quickDelete(event) } label: { Label("Delete event", systemImage: "trash") }
        }
    }

    /// Write an RSVP back to the provider (Google PATCH attendees / Microsoft
    /// accept|decline|tentativelyAccept); the engine resyncs + emits calendar-changed.
    private func quickRsvp(_ event: CalendarEvent, _ response: String) {
        Task {
            let r = await engine.respondToEvent(accountKey: event.accountKey, eventKey: event.id, response: response)
            if !r.ok { await MainActor.run { actionError = r.error } }
        }
    }

    /// Delete the event remotely + locally via the engine (write-through to the provider).
    /// An invite asks first whether to decline to the organizer.
    private func quickDelete(_ event: CalendarEvent) {
        if engine.isInvite(event) { pendingInviteDelete = event } else { runDelete(event, decline: false) }
    }

    private func runDelete(_ event: CalendarEvent, decline: Bool) {
        Task {
            let r = await engine.deleteCalendarEvent(event, decline: decline)
            if !r.ok { await MainActor.run { actionError = r.error } }
        }
    }

    /// A channel's stable colour (the lighter stop of its gradient). Used for the
    /// small month-grid dots; the agenda strip uses the full gradient directly.
    private func colorFor(_ event: CalendarEvent) -> Color {
        p.eventPastel(event) ?? ChannelColor.base(for: event.accountKey, in: channelOrder)
    }
}



/// What the calendar's create chooser offers.
enum CreateKind: Identifiable {
    case event, zone, block
    var id: Self { self }
    var title: String {
        switch self { case .event: "New event"; case .zone: "New zone"; case .block: "Block time" }
    }
    var hint: String {
        switch self {
        case .event: "Invite people to it"
        case .zone: "Focus time, still bookable"
        case .block: "Shows you as busy"
        }
    }
    var icon: String {
        switch self { case .event: "calendar.badge.plus"; case .zone: "scope"; case .block: "nosign" }
    }
}

/// Compact create chooser — confirmationDialog can't show a hint under each option,
/// so this is a short sheet with one row per choice (matches the desktop menu).
struct CreateChoiceSheet: View {
    @Environment(\.theme) private var theme
    let range: Range<Date>?
    let kinds: [CreateKind]
    let onPick: (CreateKind?) -> Void
    private var p: ThemePalette { theme.palette }

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEdMMM"); return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let r = range {
                Text("\(Self.day.string(from: r.lowerBound)) · \(ZoneStore.clock.string(from: r.lowerBound))–\(ZoneStore.clock.string(from: r.upperBound))")
                    .font(AppFont.sm).foregroundStyle(p.textSecondary)
                    .padding(.horizontal, Space.s5).padding(.bottom, Space.s2)
            }
            ForEach(kinds) { kind in
                Button { onPick(kind) } label: {
                    HStack(spacing: Space.s4) {
                        Image(systemName: kind.icon).font(AppFont.lg(.regular)).foregroundStyle(p.accentViolet)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title).font(AppFont.body).foregroundStyle(p.textPrimary)
                            Text(kind.hint).font(AppFont.xs).foregroundStyle(p.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.s5).frame(minHeight: 60).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { onPick(nil) } label: {
                Text("Cancel").font(AppFont.body).foregroundStyle(p.accentViolet)
                    .frame(maxWidth: .infinity, minHeight: 50).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Space.s2)
        }
        .padding(.top, Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(CGFloat(kinds.count) * 60 + (range == nil ? 110 : 136))])
        .presentationDragIndicator(.visible)
        .presentationBackground(p.bgRaised)
    }
}
