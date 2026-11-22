import SwiftUI
import UIKit

/// Calendar "Day" mode: a 24-hour timeline. Zones are striped bands behind the
/// events, overlapping events sit side by side, and a long-press + vertical drag
/// on empty grid picks a 15-minute-snapped range that `onCreate` turns into a new
/// event, zone or blocked window (grey hatched, tap to remove) (docs/iOS-App.md "Calendar").
struct CalendarDayView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    @ObservedObject private var zoneStore = ZoneStore.shared
    @ObservedObject private var blockStore = BlockedTimeStore.shared
    @Binding var day: Date
    let channelOrder: [String]
    /// The range the create dialog is asking about — kept drawn while it's up.
    let highlight: Range<Date>?
    let onSelect: (CalendarEvent) -> Void
    let onEditZone: (CloudZone) -> Void
    let onSelectBlock: (CloudBlockedTime) -> Void
    let onCreate: (Range<Date>) -> Void

    @State private var events: [CalendarEvent] = []
    /// Minute-of-day slots (15-min snapped) of the running long-press selection.
    @State private var dragAnchor: Int?
    @State private var dragCurrent: Int?

    private var p: ThemePalette { theme.palette }
    @ObservedObject private var zone = CalendarZone.shared
    /// The shown zone's calendar (CalendarTimeZone.swift); this device's zone unless picked.
    private var cal: Calendar { zone.calendar }
    private let hourHeight: CGFloat = 56
    private let gutter: CGFloat = 52
    private var gridHeight: CGFloat { hourHeight * 24 }

    private var dayStart: Date { cal.startOfDay(for: day) }
    private var dayEnd: Date { cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400) }

    // ── Time ↔ position (wall clock, so DST days still fit 24 rows) ──

    private func minutes(_ d: Date) -> CGFloat {
        if d <= dayStart { return 0 }
        if d >= dayEnd { return 1440 }
        let c = cal.dateComponents([.hour, .minute], from: d)
        return CGFloat((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
    private func y(_ d: Date) -> CGFloat { minutes(d) / 60 * hourHeight }
    private func date(atMinute m: Int) -> Date {
        m >= 1440 ? dayEnd : (cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: dayStart) ?? dayStart)
    }
    /// y → the 15-minute slot it falls in.
    private func slot(_ y: CGFloat) -> Int { min(1425, max(0, Int(y / hourHeight * 4) * 15)) }

    private var dragRange: Range<Date>? {
        guard let a = dragAnchor, let c = dragCurrent else { return nil }
        return date(atMinute: min(a, c)) ..< date(atMinute: max(a, c) + 15)
    }

    // ── Events ──

    private func isAllDay(_ e: CalendarEvent) -> Bool {
        e.allDay || ((e.start ?? .distantFuture) <= dayStart && (e.end ?? .distantPast) >= dayEnd)
    }
    /// All-day events by their dates in the shown zone, timed ones by their instants.
    private func onThisDay(_ e: CalendarEvent, from: Date, to: Date) -> Bool {
        if e.allDay { return zone.allDayCovers(e, from) }
        guard let s = e.start else { return false }
        return s < to && ((e.end ?? s) > from || s >= from)
    }
    private var allDayEvents: [CalendarEvent] { events.filter(isAllDay) }
    private var timedEvents: [CalendarEvent] { events.filter { !isAllDay($0) && $0.start != nil } }
    private var dayBlocks: [CloudBlockedTime] { blockStore.blocks(from: dayStart, to: dayEnd) }

    private func frames(contentW: CGFloat) -> [String: CGRect] {
        let spans = timedEvents.map { ($0.id, $0.start!, $0.end ?? $0.start!) } + dayBlocks.map { ($0.id, $0.start, $0.end) }
        return calendarOverlapFrames(spans.map { id, s, e in (id, y(s), y(e)) }, x0: gutter, width: contentW)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !allDayEvents.isEmpty { allDayStrip }
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        grid(width: geo.size.width).padding(.vertical, Space.s2)
                    }
                    // A running selection owns the finger; the scroll view waits.
                    .scrollDisabled(dragAnchor != nil)
                    .onAppear {
                        let h = cal.isDateInToday(day) ? max(0, cal.component(.hour, from: Date()) - 1) : 8
                        proxy.scrollTo(h, anchor: .top)
                    }
                }
            }
        }
        .grooveFramed()
        // Swipe left/right pages days; the vertical scroll is untouched.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                guard dragAnchor == nil, abs(dx) > 80, abs(dx) > 2 * abs(dy) else { return }
                shift(dx < 0 ? 1 : -1)
            }
        )
        .task(id: "\(dayStart.timeIntervalSince1970)|\(engine.dataVersion)") { await reload() }
        .task(id: "\(cloud.isSignedIn)|\(dayStart.timeIntervalSince1970)") {
            let from = dayStart, to = dayEnd
            guard zoneStore.enabled, !zoneStore.covers(from: from, to: to) else { return }
            await zoneStore.load(from: from.addingTimeInterval(-7 * 86_400), to: to.addingTimeInterval(7 * 86_400))
        }
        .task(id: "\(cloud.isSignedIn)|\(cloud.currentOrgId ?? "")|\(dayStart.timeIntervalSince1970)") {
            await blockStore.load(from: dayStart, to: dayEnd)
        }
    }

    private var header: some View {
        let label = DayHeader.label(day)
        let full = DayHeader.dayMonth.string(from: day)
        return HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(AppFont.title3).foregroundStyle(p.textPrimary)
                if label != full && !label.hasPrefix(full) {
                    Text(full).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                }
            }
            Spacer()
            if !cal.isDateInToday(day) {
                Button("Today") { withAnimation(.easeOut(duration: 0.18)) { day = cal.startOfDay(for: Date()) } }
                    .font(AppFont.xs(.semibold)).foregroundStyle(p.accentViolet).buttonStyle(.plain)
            }
            chevron("chevron.left", "Previous day") { shift(-1) }
            chevron("chevron.right", "Next day") { shift(1) }
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

    private func shift(_ delta: Int) {
        guard let next = cal.date(byAdding: .day, value: delta, to: dayStart) else { return }
        withAnimation(.easeOut(duration: 0.18)) { day = next }
    }

    private var allDayStrip: some View {
        HStack(spacing: 0) {
            Text("all-day").font(AppFont.xs3).foregroundStyle(p.textTertiary)
                .frame(width: gutter - Space.s2, alignment: .trailing)
                .padding(.trailing, Space.s2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s1) {
                    ForEach(allDayEvents) { ev in
                        let tone = p.eventFill(ev)
                        Button { onSelect(ev) } label: {
                            Text(ev.title).font(AppFont.xs2(.semibold))
                                .foregroundStyle(p.eventInk(ev) ?? p.textPrimary).lineLimit(1)
                                .padding(.horizontal, Space.s2).padding(.vertical, 4)
                                .background(tone ?? ChannelColor.base(for: ev.accountKey, in: channelOrder).opacity(0.22),
                                            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, Space.s2)
            }
        }
        .padding(.vertical, Space.s1)
    }

    // ── The grid ──

    private func grid(width: CGFloat) -> some View {
        let contentW = max(0, width - gutter - Space.s2)
        let rects = frames(contentW: contentW)
        return ZStack(alignment: .topLeading) {
            // Hour labels double as the scroll anchors.
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d:00", h)).font(AppFont.xs3).monospacedDigit()
                        .foregroundStyle(p.textTertiary)
                        .frame(width: gutter - Space.s2, height: hourHeight, alignment: .topTrailing)
                        .offset(y: -6)
                        .id(h)
                }
            }
            gridLines.frame(width: width, height: gridHeight).allowsHitTesting(false)

            // Empty grid: long-press then drag selects a range.
            Color.clear.contentShape(Rectangle())
                .frame(width: contentW, height: gridHeight)
                .offset(x: gutter)
                .gesture(RangePress { state, point in pressChanged(state, point) })

            ForEach(zoneStore.zones(on: day)) { z in
                let top = y(z.start)
                DayZoneBand(zone: z, height: max(y(z.end) - top, 24)) { onEditZone(z) }
                    .frame(width: contentW)
                    .offset(x: gutter, y: top)
            }

            ForEach(dayBlocks) { b in
                if let r = rects[b.id] {
                    Button { onSelectBlock(b) } label: { CalendarBlockedBlock(block: b, height: r.height) }
                        .buttonStyle(.plain)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .accessibilityLabel("Blocked, \(ZoneStore.clock.string(from: b.start)) to \(ZoneStore.clock.string(from: b.end))")
                }
            }

            ForEach(timedEvents) { ev in
                if let r = rects[ev.id] {
                    Button { onSelect(ev) } label: { CalendarEventBlock(ev: ev, height: r.height, channelOrder: channelOrder) }
                        .buttonStyle(.plain)
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
            }

            if cal.isDateInToday(day) { nowLine(contentW) }

            if let r = dragRange ?? highlight, r.lowerBound < dayEnd, r.upperBound > dayStart {
                selection(r, contentW)
            }
        }
        .frame(width: width, height: gridHeight, alignment: .topLeading)
    }

    /// Hour lines + dotted half-hours: two strokes in one Canvas.
    private var gridLines: some View {
        Canvas { ctx, size in
            var hours = Path(), halves = Path()
            for h in 0...24 {
                let y = CGFloat(h) * hourHeight
                hours.move(to: CGPoint(x: gutter, y: y)); hours.addLine(to: CGPoint(x: size.width, y: y))
                if h < 24 {
                    halves.move(to: CGPoint(x: gutter, y: y + hourHeight / 2))
                    halves.addLine(to: CGPoint(x: size.width, y: y + hourHeight / 2))
                }
            }
            let line = p.calendarGridLine ?? p.borderDefault
            ctx.stroke(hours, with: .color(line), lineWidth: 0.5)
            ctx.stroke(halves, with: .color(line.opacity(0.6)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
    }

    private func nowLine(_ contentW: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            let ny = y(ctx.date)
            ZStack(alignment: .topLeading) {
                let tone = p.calendarNowLine ?? p.accentDanger
                Rectangle().fill(tone).frame(width: contentW + 4, height: 1.5).offset(x: gutter - 4, y: ny - 0.75)
                Circle().fill(tone).frame(width: 8, height: 8).offset(x: gutter - 8, y: ny - 4)
            }
        }
        .allowsHitTesting(false)
    }

    private func selection(_ r: Range<Date>, _ contentW: CGFloat) -> some View {
        let top = y(r.lowerBound)
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        return Text("\(ZoneStore.clock.string(from: r.lowerBound)) – \(ZoneStore.clock.string(from: r.upperBound))")
            .font(AppFont.xs2(.semibold)).monospacedDigit().foregroundStyle(p.accentViolet)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(width: contentW, height: max(y(r.upperBound) - top, 14), alignment: .topLeading)
            .background(p.accentViolet.opacity(0.2), in: shape)
            .overlay(shape.strokeBorder(p.accentViolet, lineWidth: 1.5))
            .offset(x: gutter, y: top)
            .allowsHitTesting(false)
    }

    private func pressChanged(_ state: UIGestureRecognizer.State, _ point: CGPoint) {
        switch state {
        case .began:
            dragAnchor = slot(point.y); dragCurrent = dragAnchor
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            let s = slot(point.y)
            if s != dragCurrent { dragCurrent = s; UISelectionFeedbackGenerator().selectionChanged() }
        case .ended:
            if let r = dragRange { onCreate(r) }
            dragAnchor = nil; dragCurrent = nil
        default:
            dragAnchor = nil; dragCurrent = nil
        }
    }

    private func reload() async {
        let from = dayStart, to = dayEnd
        // A day wider each side for all-day events at this device's midnight (CalendarZone).
        let fromISO = isoLocalInternet.string(from: from.addingTimeInterval(-86_400))
        let toISO = isoLocalInternet.string(from: to.addingTimeInterval(86_400))
        let result = await engine.store.read { $0.eventsBetween(fromISO: fromISO, toISO: toISO) }
        guard !Task.isCancelled else { return }
        // The query's `end >= from` also returns what ends exactly at midnight.
        events = result.filter { onThisDay($0, from: from, to: to) }
        zoneStore.reconcileAnchors(result)
    }
}

/// Block frames shared by the Day and Week grids: overlapping spans (events, and
/// blocked windows, which lay out like events) split `width` into columns, one
/// greedy column assignment per overlap cluster. Spans are (id, top y, bottom y).
func calendarOverlapFrames(_ spans: [(id: String, lo: CGFloat, hi: CGFloat)],
                           x0: CGFloat, width: CGFloat) -> [String: CGRect] {
    let items = spans.map { (id: $0.id, lo: $0.lo, hi: max($0.hi, $0.lo + 22)) }.sorted { $0.lo < $1.lo }
    var out: [String: CGRect] = [:]
    var cluster: [(id: String, lo: CGFloat, hi: CGFloat, col: Int)] = []
    var colEnds: [CGFloat] = []
    var clusterEnd: CGFloat = -1
    func flush() {
        let w = width / CGFloat(max(1, colEnds.count))
        for c in cluster { out[c.id] = CGRect(x: x0 + CGFloat(c.col) * w, y: c.lo, width: w, height: c.hi - c.lo) }
        cluster = []; colEnds = []
    }
    for it in items {
        if it.lo >= clusterEnd { flush() }
        let col: Int
        if let i = colEnds.firstIndex(where: { $0 <= it.lo }) { colEnds[i] = it.hi; col = i }
        else { colEnds.append(it.hi); col = colEnds.count - 1 }
        cluster.append((it.id, it.lo, it.hi, col))
        clusterEnd = max(clusterEnd, it.hi)
    }
    flush()
    return out
}

/// A timed event on the Day / Week grid.
struct CalendarEventBlock: View {
    @Environment(\.theme) private var theme
    let ev: CalendarEvent
    let height: CGFloat
    let channelOrder: [String]
    private var p: ThemePalette { theme.palette }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        let range = ev.endTimeLabel.isEmpty ? ev.startTimeLabel : "\(ev.startTimeLabel) – \(ev.endTimeLabel)"
        // Groovebox: a solid pastel block with dark ink, no rail.
        let tone = p.eventFill(ev)
        let ink = p.eventInk(ev)
        return HStack(spacing: 0) {
            if tone == nil {
                Rectangle().fill(ChannelColor.gradient(for: ev.accountKey, in: channelOrder)).frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ev.title).font(AppFont.xs2(.semibold)).foregroundStyle(ink ?? p.textPrimary)
                    .lineLimit(height > 44 ? 2 : 1)
                if height >= 34 {
                    Text(range).font(AppFont.xs3).foregroundStyle(ink?.opacity(0.7) ?? p.textSecondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Opaque base so the zone stripes don't show through the tint.
        .background {
            if let tone {
                shape.fill(tone)
            } else {
                ZStack { shape.fill(p.bgBase); shape.fill(ChannelColor.base(for: ev.accountKey, in: channelOrder).opacity(0.22)) }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(p.bgBase, lineWidth: 1))   // gap between side-by-side blocks
        .opacity(ev.isPast && tone == nil ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

/// A blocked window: neutral grey hatch (the zone fill in `textTertiary`) over an
/// opaque base, "Blocked" + the range.
struct CalendarBlockedBlock: View {
    @Environment(\.theme) private var theme
    let block: CloudBlockedTime
    let height: CGFloat
    private var p: ThemePalette { theme.palette }

    var body: some View {
        let b = block
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        return VStack(alignment: .leading, spacing: 1) {
            Text("Blocked").font(AppFont.xs2(.semibold)).foregroundStyle(p.solidChipInk ?? p.textSecondary).lineLimit(1)
            if height >= 34 {
                Text("\(ZoneStore.clock.string(from: b.start)) – \(ZoneStore.clock.string(from: b.end))")
                    .font(AppFont.xs3).monospacedDigit().foregroundStyle(p.solidChipInk?.opacity(0.7) ?? p.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { ZStack { shape.fill(p.bgBase); ZoneFill(tone: p.textTertiary, radius: Radius.md, hatch: 0.16) } }
        .overlay(shape.strokeBorder(p.textTertiary.opacity(0.45), lineWidth: 1))
        .padding(1)   // gap between side-by-side blocks
        .opacity(b.end < Date() ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

/// A zone behind the day grid: striped tint + outline over its span, label (category
/// · name, "N left" while active) at the top-left. Only the label takes touches, so
/// the band stays a drag-to-create target.
struct DayZoneBand: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = ZoneStore.shared
    let zone: CloudZone
    let height: CGFloat
    let onTap: () -> Void
    private var p: ThemePalette { theme.palette }

    var body: some View {
        let cat = store.category(zone.categoryId)
        let tone = p.zone(cat?.color)
        let label = p.solidChipInk ?? tone.mix(with: p.textPrimary, by: 0.35)
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let active = zone.isActive(at: ctx.date)
            ZStack(alignment: .topLeading) {
                ZoneFill(tone: tone, radius: Radius.lg)
                    .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .strokeBorder(tone.opacity(active ? 0.85 : 0.45), lineWidth: active ? 1.5 : 1))
                    .allowsHitTesting(false)
                Button(action: onTap) {
                    HStack(spacing: 5) {
                        Circle().fill(tone).frame(width: 6, height: 6)
                        Text((cat?.name ?? "Zone").uppercased()).font(AppFont.xs3).tracking(0.6).foregroundStyle(label)
                        Text(zone.name).font(AppFont.xs2(.semibold)).foregroundStyle(p.solidChipInk ?? p.textPrimary)
                        if active {
                            Text(zoneRemainingLabel(zone.end, now: ctx.date))
                                .font(AppFont.xs3(.semibold)).monospacedDigit().foregroundStyle(label)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(tone.opacity(0.22), in: Capsule())
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, Space.s2).padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: height, alignment: .topLeading)
            .opacity(zone.end < ctx.date ? 0.5 : 1)
        }
    }
}

/// UIKit long-press (0.3 s) reporting its location — SwiftUI's `LongPressGesture`
/// has none. Once it begins the scroll view's pan can't, so plain scrolls still
/// scroll and only a held finger starts a selection.
struct RangePress: UIGestureRecognizerRepresentable {
    let onChange: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.3
        return g
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        onChange(recognizer.state, context.converter.localLocation)
    }
}

extension ThemePalette {
    /// Groovebox: the pastel for a colour key — the ring pastels + pink + LED green,
    /// hashed per calendar. nil = the existing channel-coloured look.
    func eventPastel(key: String) -> Color? {
        guard solidChipInk != nil else { return nil }
        let pastels = ringColors + [statusSnoozed] + (unreadLED.map { [$0] } ?? [])
        return pastels[ChannelColor.index(for: key) % pastels.count]
    }
    func eventPastel(_ ev: CalendarEvent) -> Color? { eventPastel(key: ev.pastelKey) }
    /// Groovebox block fill: the pastel, or for an event that has ended its muted
    /// step (45% pastel into the grid ground) — never a whole-card fade.
    func eventFill(_ ev: CalendarEvent) -> Color? {
        eventPastel(ev).map { ev.isPast ? GrooveboxScene.ground.mix(with: $0, by: 0.45) : $0 }
    }
    /// Groovebox ink on `eventFill`: dark on a live pastel, light on the muted step.
    func eventInk(_ ev: CalendarEvent) -> Color? {
        guard eventPastel(ev) != nil else { return nil }
        return ev.isPast ? textSecondary : solidChipInk
    }
    /// Small labels that sit on a solid Groovebox panel never drop below
    /// `textTertiary`; other themes keep `textMuted`.
    var faintLabel: Color { panelRadius != nil ? textTertiary : textMuted }
}

extension CalendarEvent {
    /// Groovebox colour key: one pastel per calendar (account + calendar name), so
    /// events from different calendars on one account still differ.
    var pastelKey: String { "\(accountKey)|\(calendarName ?? "")" }
}
