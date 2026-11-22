import SwiftUI

/// The iPad sidebar's calendar page pieces, after desktop's `CalendarSidebar`: a mini
/// month (tap a day → the grid jumps there) and "Coming up". Both talk to
/// `CalendarView` through `ChromeModel` (`calendarDay` / `calendarJump`, and
/// `pendingCalendarEventKey` to open an event).

struct SidebarMiniMonth: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var chrome: ChromeModel
    /// Any day in the shown month; follows the grid's day until the user pages.
    @State private var anchor = Date()
    @ObservedObject private var zone = CalendarZone.shared
    private var cal: Calendar { zone.calendar }
    private var p: ThemePalette { theme.palette }

    private var monthStart: Date { cal.dateInterval(of: .month, for: anchor)?.start ?? anchor }
    /// Six full weeks from the week holding the 1st.
    private var cells: [Date] {
        let first = cal.dateInterval(of: .weekOfYear, for: monthStart)?.start ?? monthStart
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: first) }
    }
    private static let title: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMMy"); return f }()

    var body: some View {
        VStack(spacing: Space.s1) {
            HStack {
                Text({ Self.title.timeZone = cal.timeZone; return Self.title.string(from: monthStart) }()).font(AppFont.sm(.semibold)).foregroundStyle(p.textPrimary)
                Spacer()
                page("chevron.left", -1)
                page("chevron.right", 1)
            }
            let symbols = cal.veryShortStandaloneWeekdaySymbols
            let order = (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
            HStack(spacing: 0) {
                ForEach(Array(order.enumerated()), id: \.offset) { _, s in
                    Text(s).font(AppFont.xs3(.semibold)).foregroundStyle(p.textTertiary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(cells, id: \.self) { d in cell(d) }
            }
        }
        .padding(.horizontal, Space.s4).padding(.vertical, Space.s3)
        .onChange(of: chrome.calendarDay, initial: true) { _, d in anchor = d }
    }

    private func page(_ icon: String, _ delta: Int) -> some View {
        Button { anchor = cal.date(byAdding: .month, value: delta, to: monthStart) ?? anchor } label: {
            Image(systemName: icon).font(AppFont.xs(.semibold)).foregroundStyle(p.textSecondary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cell(_ d: Date) -> some View {
        let inMonth = cal.isDate(d, equalTo: monthStart, toGranularity: .month)
        let selected = cal.isDate(d, inSameDayAs: chrome.calendarDay)
        let today = cal.isDateInToday(d)
        return Button { chrome.calendarJump = d } label: {
            Text("\(cal.component(.day, from: d))")
                .font(AppFont.xs(today || selected ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(selected ? p.onAccent : today ? p.accentViolet : inMonth ? p.textSecondary : p.textMuted)
                .frame(width: 26, height: 26)
                .background { if selected { Circle().fill(p.accentViolet) } }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The next few events (from today), each opening its detail sheet.
struct SidebarComingUp: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var zone = CalendarZone.shared
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var chrome: ChromeModel
    @State private var events: [CalendarEvent] = []
    private var p: ThemePalette { theme.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if events.isEmpty {
                Text("Nothing coming up").font(AppFont.xs).foregroundStyle(p.textTertiary)
                    .padding(.horizontal, Space.s5).padding(.vertical, Space.s3)
            }
            ForEach(events) { ev in
                Button { chrome.pendingCalendarEventKey = ev.id } label: {
                    HStack(alignment: .top, spacing: Space.s2) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(ChannelColor.gradient(for: ev.accountKey, in: engine.accounts.map(\.id)))
                            .frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ev.title).font(AppFont.xs(.semibold)).foregroundStyle(p.textPrimary).lineLimit(1)
                            Text("\(DayHeader.label(zone.day(of: ev))) · \(ev.startTimeLabel)")
                                .font(AppFont.xs3).foregroundStyle(p.textTertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: "\(engine.dataVersion)|\(zone.timeZone.identifier)") {
            // The next six from now, plus all-day events that started a day back but
            // still fall on today in the shown zone (they sit at this device's midnight).
            let now = Date()
            let today = zone.calendar.startOfDay(for: now)
            let fromNow = isoLocalInternet.string(from: now)
            let dayBack = isoLocalInternet.string(from: now.addingTimeInterval(-86_400))
            let dayOn = isoLocalInternet.string(from: now.addingTimeInterval(86_400))
            // All-day events from their own two-day window, so no busy morning crowds them out.
            let (next, early) = await engine.store.read {
                ($0.upcomingEvents(fromISO: fromNow, limit: 6), $0.eventsBetween(fromISO: dayBack, toISO: dayOn))
            }
            if !Task.isCancelled {
                let allDay = early.filter { $0.allDay && zone.isCurrent($0, from: today) }
                var seen = Set<String>()
                events = Array((allDay + next).filter { seen.insert($0.id).inserted }
                    .sorted { zone.day(of: $0) != zone.day(of: $1) ? zone.day(of: $0) < zone.day(of: $1) : !$0.allDay && $1.allDay ? false : ($0.start ?? now) < ($1.start ?? now) }
                    .prefix(6))
            }
        }
    }
}
