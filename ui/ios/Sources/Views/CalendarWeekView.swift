import SwiftUI
import UIKit

/// Calendar "Week" mode (iPad): desktop's week grid — seven day columns on one
/// 24-hour timeline. Built from the Day view's pieces (overlap layout, event and
/// blocked blocks, zone bands, long-press range create), one column per day; a
/// day's header opens it in Day mode, a horizontal swipe pages weeks.
struct CalendarWeekView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    @ObservedObject private var zoneStore = ZoneStore.shared
    @ObservedObject private var blockStore = BlockedTimeStore.shared
    /// Any day in the shown week.
    @Binding var day: Date
    let channelOrder: [String]
    /// The range the create dialog is asking about — kept drawn while it's up.
    let highlight: Range<Date>?
    let onSelect: (CalendarEvent) -> Void
    let onEditZone: (CloudZone) -> Void
    let onSelectBlock: (CloudBlockedTime) -> Void
    let onCreate: (Range<Date>) -> Void
    let onOpenDay: (Date) -> Void

    @State private var events: [CalendarEvent] = []
    /// The running long-press selection: its column and 15-min minute-of-day slots.
    @State private var dragCol: Int?
    @State private var dragAnchor: Int?
    @State private var dragCurrent: Int?

    private var p: ThemePalette { theme.palette }
    @ObservedObject private var zone = CalendarZone.shared
    /// The shown zone's calendar (CalendarTimeZone.swift); this device's zone unless picked.
    private var cal: Calendar { zone.calendar }
    private let hourHeight: CGFloat = 48
    private let gutter: CGFloat = 52
    private var gridHeight: CGFloat { hourHeight * 24 }

    private var weekStart: Date { cal.dateInterval(of: .weekOfYear, for: day)?.start ?? cal.startOfDay(for: day) }
    private var days: [Date] { (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) } }
    private func next(_ d: Date) -> Date { cal.date(byAdding: .day, value: 1, to: d) ?? d.addingTimeInterval(86_400) }
    private var weekEnd: Date { next(days.last ?? weekStart) }

    // ── Time ↔ position (wall clock, clamped to the column's day) ──

    private func y(_ d: Date, in dayStart: Date) -> CGFloat {
        if d <= dayStart { return 0 }
        if d >= next(dayStart) { return gridHeight }
        let c = cal.dateComponents([.hour, .minute], from: d)
        return CGFloat((c.hour ?? 0) * 60 + (c.minute ?? 0)) / 60 * hourHeight
    }
    private func date(atMinute m: Int, in dayStart: Date) -> Date {
        m >= 1440 ? next(dayStart) : (cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: dayStart) ?? dayStart)
    }
    private func slot(_ y: CGFloat) -> Int { min(1425, max(0, Int(y / hourHeight * 4) * 15)) }

    private var dragRange: Range<Date>? {
        guard let col = dragCol, let a = dragAnchor, let c = dragCurrent, days.indices.contains(col) else { return nil }
        return date(atMinute: min(a, c), in: days[col]) ..< date(atMinute: max(a, c) + 15, in: days[col])
    }

    // ── Events per day ──

    private func overlaps(_ e: CalendarEvent, _ dayStart: Date) -> Bool {
        if e.allDay { return zone.allDayCovers(e, dayStart) }   // by date, in any shown zone
        guard let s = e.start else { return false }
        return s < next(dayStart) && ((e.end ?? s) > dayStart || s >= dayStart)
    }
    private func isAllDay(_ e: CalendarEvent, _ dayStart: Date) -> Bool {
        e.allDay || ((e.start ?? .distantFuture) <= dayStart && (e.end ?? .distantPast) >= next(dayStart))
    }
    private func allDay(_ d: Date) -> [CalendarEvent] { events.filter { overlaps($0, d) && isAllDay($0, d) } }
    private func timed(_ d: Date) -> [CalendarEvent] { events.filter { overlaps($0, d) && !isAllDay($0, d) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            dayHeaders
            if days.contains(where: { !allDay($0).isEmpty }) { allDayRow }
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        grid(width: geo.size.width).padding(.vertical, Space.s2)
                    }
                    .scrollDisabled(dragAnchor != nil)
                    .onAppear {
                        let inWeek = days.contains { cal.isDateInToday($0) }
                        proxy.scrollTo(inWeek ? max(0, cal.component(.hour, from: Date()) - 1) : 8, anchor: .top)
                    }
                }
            }
        }
        .grooveFramed()
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                guard dragAnchor == nil, abs(dx) > 80, abs(dx) > 2 * abs(dy) else { return }
                shift(dx < 0 ? 1 : -1)
            }
        )
        .task(id: "\(weekStart.timeIntervalSince1970)|\(engine.dataVersion)") { await reload() }
        .task(id: "\(cloud.isSignedIn)|\(weekStart.timeIntervalSince1970)") {
            let from = weekStart, to = weekEnd
            guard zoneStore.enabled, !zoneStore.covers(from: from, to: to) else { return }
            await zoneStore.load(from: from.addingTimeInterval(-7 * 86_400), to: to.addingTimeInterval(7 * 86_400))
        }
        .task(id: "\(cloud.isSignedIn)|\(cloud.currentOrgId ?? "")|\(weekStart.timeIntervalSince1970)") {
            await blockStore.load(from: weekStart, to: weekEnd)
        }
    }

    private static let range: DateIntervalFormatter = {
        let f = DateIntervalFormatter(); f.dateTemplate = "MMMdy"; return f
    }()

    private var header: some View {
        HStack(spacing: Space.s3) {
            Text({ Self.range.timeZone = cal.timeZone; return Self.range.string(from: weekStart, to: days.last ?? weekStart) }())
                .font(AppFont.title3).foregroundStyle(p.textPrimary)
            Spacer()
            if !days.contains(where: { cal.isDateInToday($0) }) {
                Button("Today") { withAnimation(.easeOut(duration: 0.18)) { day = cal.startOfDay(for: Date()) } }
                    .font(AppFont.xs(.semibold)).foregroundStyle(p.accentViolet).buttonStyle(.plain)
            }
            chevron("chevron.left", "Previous week") { shift(-1) }
            chevron("chevron.right", "Next week") { shift(1) }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s1)
    }

    private func chevron(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(AppFont.md(.semibold))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(p.accentViolet)
        .accessibilityLabel(label)
    }

    private func shift(_ weeks: Int) {
        guard let d = cal.date(byAdding: .weekOfYear, value: weeks, to: weekStart) else { return }
        withAnimation(.easeOut(duration: 0.18)) { day = d }
    }

    private static let weekday: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f }()

    /// "Mon 20" per column; today's number sits in an accent disc. Tap opens the day.
    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let today = cal.isDateInToday(d)
                Button { onOpenDay(d) } label: {
                    HStack(spacing: 5) {
                        Text({ Self.weekday.timeZone = cal.timeZone; return Self.weekday.string(from: d) }()).font(AppFont.xs(.medium))
                            .foregroundStyle(today ? p.accentViolet : p.textTertiary)
                        Text("\(cal.component(.day, from: d))").font(AppFont.sm(.semibold)).monospacedDigit()
                            .foregroundStyle(today ? p.onAccent : p.textPrimary)
                            .frame(minWidth: 26, minHeight: 26)
                            .background { if today { Circle().fill(p.accentViolet) } }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(DayHeader.dayMonth.string(from: d))
            }
        }
        .padding(.bottom, Space.s1)
    }

    /// All-day events per column: two chips, then "+N" (tap opens the day).
    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day").font(AppFont.xs3).foregroundStyle(p.textTertiary)
                .frame(width: gutter - Space.s2, alignment: .trailing)
                .padding(.trailing, Space.s2).padding(.top, 4)
            ForEach(days, id: \.self) { d in
                let items = allDay(d)
                VStack(spacing: 2) {
                    ForEach(items.prefix(2)) { ev in
                        Button { onSelect(ev) } label: {
                            Text(ev.title).font(AppFont.xs3(.semibold))
                                .foregroundStyle(p.eventInk(ev) ?? p.textPrimary).lineLimit(1)
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(p.eventFill(ev) ?? ChannelColor.base(for: ev.accountKey, in: channelOrder).opacity(0.22),
                                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if items.count > 2 {
                        Button("+\(items.count - 2)") { onOpenDay(d) }
                            .font(AppFont.xs3(.semibold)).foregroundStyle(p.textSecondary).buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .padding(.vertical, Space.s1)
    }

    // ── The grid ──

    private func grid(width: CGFloat) -> some View {
        let colW = max(0, (width - gutter) / 7)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d:00", h)).font(AppFont.xs3).monospacedDigit()
                        .foregroundStyle(p.textTertiary)
                        .frame(width: gutter - Space.s2, height: hourHeight, alignment: .topTrailing)
                        .offset(y: -6)
                        .id(h)
                }
            }
            gridLines(colW).frame(width: width, height: gridHeight).allowsHitTesting(false)
            ForEach(Array(days.enumerated()), id: \.element) { i, d in
                column(i, d, colW).offset(x: gutter + CGFloat(i) * colW)
            }
        }
        .frame(width: width, height: gridHeight, alignment: .topLeading)
    }

    private func column(_ i: Int, _ d: Date, _ colW: CGFloat) -> some View {
        let inner = max(0, colW - 2)
        let blocks = blockStore.blocks(from: d, to: next(d))
        let evs = timed(d)
        let spans = evs.map { ($0.id, $0.start!, $0.end ?? $0.start!) } + blocks.map { ($0.id, $0.start, $0.end) }
        let rects = calendarOverlapFrames(spans.map { id, s, e in (id, y(s, in: d), y(e, in: d)) }, x0: 1, width: inner)
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .frame(width: colW, height: gridHeight)
                .gesture(RangePress { state, point in pressChanged(i, state, point) })

            ForEach(zoneStore.zones(on: d)) { z in
                let top = y(z.start, in: d)
                DayZoneBand(zone: z, height: max(y(z.end, in: d) - top, 24)) { onEditZone(z) }
                    .frame(width: inner).clipped()
                    .offset(x: 1, y: top)
            }
            ForEach(blocks) { b in
                if let r = rects[b.id] {
                    Button { onSelectBlock(b) } label: { CalendarBlockedBlock(block: b, height: r.height) }
                        .buttonStyle(.plain)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
            ForEach(evs) { ev in
                if let r = rects[ev.id] {
                    Button { onSelect(ev) } label: { CalendarEventBlock(ev: ev, height: r.height, channelOrder: channelOrder) }
                        .buttonStyle(.plain)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }
            if cal.isDateInToday(d) { nowLine(d, colW) }
            if let r = dragRange ?? highlight, r.lowerBound < next(d), r.lowerBound >= d {
                selection(r, d, inner)
            }
        }
        .frame(width: colW, height: gridHeight, alignment: .topLeading)
    }

    /// Hour lines, dotted half-hours and the day dividers: one Canvas.
    private func gridLines(_ colW: CGFloat) -> some View {
        Canvas { ctx, size in
            var hours = Path(), halves = Path(), cols = Path()
            for h in 0...24 {
                let y = CGFloat(h) * hourHeight
                hours.move(to: CGPoint(x: gutter, y: y)); hours.addLine(to: CGPoint(x: size.width, y: y))
                if h < 24 {
                    halves.move(to: CGPoint(x: gutter, y: y + hourHeight / 2))
                    halves.addLine(to: CGPoint(x: size.width, y: y + hourHeight / 2))
                }
            }
            for i in 0...7 {
                let x = gutter + CGFloat(i) * colW
                cols.move(to: CGPoint(x: x, y: 0)); cols.addLine(to: CGPoint(x: x, y: size.height))
            }
            let line = p.calendarGridLine ?? p.borderDefault
            ctx.stroke(hours, with: .color(line), lineWidth: 0.5)
            ctx.stroke(cols, with: .color(line), lineWidth: 0.5)
            ctx.stroke(halves, with: .color(line.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
    }

    private func nowLine(_ d: Date, _ colW: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let ny = y(ctx.date, in: d)
            let tone = p.calendarNowLine ?? p.accentDanger
            ZStack(alignment: .topLeading) {
                Rectangle().fill(tone).frame(width: colW, height: 1.5).offset(y: ny - 0.75)
                Circle().fill(tone).frame(width: 8, height: 8).offset(x: -4, y: ny - 4)
            }
        }
        .allowsHitTesting(false)
    }

    private func selection(_ r: Range<Date>, _ d: Date, _ inner: CGFloat) -> some View {
        let top = y(r.lowerBound, in: d)
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        return Text("\(ZoneStore.clock.string(from: r.lowerBound)) – \(ZoneStore.clock.string(from: r.upperBound))")
            .font(AppFont.xs3(.semibold)).monospacedDigit().foregroundStyle(p.accentViolet).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 3)
            .frame(width: inner, height: max(y(r.upperBound, in: d) - top, 14), alignment: .topLeading)
            .background(p.accentViolet.opacity(0.2), in: shape)
            .overlay(shape.strokeBorder(p.accentViolet, lineWidth: 1.5))
            .offset(x: 1, y: top)
            .allowsHitTesting(false)
    }

    private func pressChanged(_ col: Int, _ state: UIGestureRecognizer.State, _ point: CGPoint) {
        switch state {
        case .began:
            dragCol = col; dragAnchor = slot(point.y); dragCurrent = dragAnchor
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            let s = slot(point.y)
            if s != dragCurrent { dragCurrent = s; UISelectionFeedbackGenerator().selectionChanged() }
        case .ended:
            if let r = dragRange { onCreate(r) }
            dragCol = nil; dragAnchor = nil; dragCurrent = nil
        default:
            dragCol = nil; dragAnchor = nil; dragCurrent = nil
        }
    }

    private func reload() async {
        let from = weekStart, to = weekEnd
        // A day wider each side for all-day events at this device's midnight (CalendarZone).
        let fromISO = isoLocalInternet.string(from: from.addingTimeInterval(-86_400))
        let toISO = isoLocalInternet.string(from: to.addingTimeInterval(86_400))
        let result = await engine.store.read { $0.eventsBetween(fromISO: fromISO, toISO: toISO) }
        guard !Task.isCancelled else { return }
        events = result
        zoneStore.reconcileAnchors(result)
    }
}
