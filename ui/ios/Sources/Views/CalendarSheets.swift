import SwiftUI

/// A horizontally-scrollable load gauge spanning ±30 days: one stacked bar per day,
/// each segment coloured by the channel its events belong to. No card — it reads as
/// an inline glance of how busy you are, opening on today (scroll left for the past
/// 30 days, right for the next 30). Bar colours line up with the agenda strips below
/// it and scale to the busiest day in the window.
struct UpcomingLoadChart: View {
    @Environment(\.theme) private var theme
    let events: [CalendarEvent]
    let channelOrder: [String]
    let selectedDay: Date?
    let onSelect: (Date) -> Void
    @State private var scrollEnabled = true   // toggled to kill momentum on "Today"
    private var p: ThemePalette { theme.palette }
    private let cal = Calendar.current
    private let maxBarHeight: CGFloat = 54
    private let barWidth: CGFloat = 18
    private let columnWidth: CGFloat = 30
    private let pastDays = 30
    private let futureDays = 30

    /// One day's stacked load: channel segments (stable by first appearance) + total.
    private struct DayLoad: Identifiable {
        let day: Date
        let segments: [(key: String, count: Int)]
        let total: Int
        var id: TimeInterval { day.timeIntervalSince1970 }
    }

    private var today: Date { cal.startOfDay(for: Date()) }
    private var todayID: TimeInterval { today.timeIntervalSince1970 }

    /// The full ±30-day window (today−30 … today+30), each day bucketed by channel.
    /// Built in a single pass over `events` (one date-parse per event) so a render
    /// is O(N) — not O(days × events) — and computed once per body, not per column.
    private func computeLoads() -> [DayLoad] {
        var counts: [Date: [String: Int]] = [:]
        var order: [Date: [String]] = [:]
        // Groovebox colours bars per calendar (its pastel mapping); else per channel.
        let perCalendar = p.solidChipInk != nil
        for ev in events {
            let day = ev.dayKey
            let key = perCalendar ? ev.pastelKey : ev.accountKey
            if counts[day]?[key] == nil { order[day, default: []].append(key) }
            counts[day, default: [:]][key, default: 0] += 1
        }
        return (-pastDays...futureDays).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { return nil }
            let c = counts[day] ?? [:]
            let segs = (order[day] ?? []).map { (key: $0, count: c[$0] ?? 0) }
            return DayLoad(day: day, segments: segs, total: c.values.reduce(0, +))
        }
    }

    var body: some View {
        let loads = computeLoads()
        let maxTotal = max(loads.map(\.total).max() ?? 0, 1)
        let upcomingTotal = loads.reduce(0) { $1.day >= today ? $0 + $1.total : $0 }
        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text("MEETING LOAD")
                        .font(AppFont.xs3).tracking(0.7).foregroundStyle(p.textTertiary)
                    // Toggle today's selection and jump to it. scrollTo alone can't
                    // interrupt an in-flight momentum scroll, so briefly disable the
                    // scroll to halt it, then re-enable and jump on the next tick.
                    Button {
                        onSelect(today)
                        scrollEnabled = false
                        DispatchQueue.main.async {
                            scrollEnabled = true
                            DispatchQueue.main.async {
                                proxy.scrollTo(todayID, anchor: UnitPoint(x: 0.12, y: 0))
                            }
                        }
                    } label: {
                        Text("Today").font(AppFont.xs3).foregroundStyle(p.accentViolet)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(upcomingTotal) upcoming")
                        .font(AppFont.xs3).foregroundStyle(p.textSecondary)
                    + Text(" / \(futureDays)d")
                        .font(AppFont.xs3).foregroundStyle(p.faintLabel)
                }
                .padding(.horizontal, Space.s4)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .bottom, spacing: 6) {
                        ForEach(loads) { column($0, maxTotal: maxTotal).id($0.id) }
                    }
                    .padding(.horizontal, Space.s4)
                }
                .scrollDisabled(!scrollEnabled)
                .frame(height: maxBarHeight + 54)   // size to a column; don't expand vertically
                .onAppear { proxy.scrollTo(todayID, anchor: UnitPoint(x: 0.12, y: 0)) }
            }
        }
    }

    private func column(_ load: DayLoad, maxTotal: Int) -> some View {
        let isToday = cal.isDateInToday(load.day)
        let isPast = load.day < today
        let isSelected = selectedDay.map { cal.isDate($0, inSameDayAs: load.day) } ?? false
        let labelColor: Color = isToday ? (p.unreadLED ?? p.accentViolet) : (isPast ? p.faintLabel : p.textTertiary)
        return Button { onSelect(load.day) } label: {
            VStack(spacing: 5) {
                Text(load.total > 0 ? "\(load.total)" : " ")
                    .font(AppFont.xs3)
                    .foregroundStyle(load.total > 0 ? (isPast ? p.textTertiary : p.textSecondary) : .clear)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .fill(isToday ? AnyShapeStyle(p.accentViolet.opacity(0.12))
                              : AnyShapeStyle(p.panelRadius != nil ? p.bgRaised : p.borderDefault))
                        .frame(width: barWidth, height: maxBarHeight)
                    // Groovebox mutes past bars per segment (see `bar`), not by fading.
                    bar(load, maxTotal: maxTotal, past: isPast).opacity(isPast && p.solidChipInk == nil ? 0.5 : 1)
                }
                .frame(height: maxBarHeight, alignment: .bottom)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .inset(by: -4)
                            .strokeBorder(
                                LinearGradient(colors: p.ringColors,
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1.5)
                    }
                }
                VStack(spacing: 1) {
                    Text(weekdayLetter(load.day))
                        .font(AppFont.xs3).foregroundStyle(labelColor)
                    Text("\(cal.component(.day, from: load.day))")
                        .font(AppFont.xs2((isToday || isSelected) ? .bold : .regular))
                        .foregroundStyle(isToday ? p.accentViolet : (isPast ? p.faintLabel : p.textSecondary))
                }
            }
            .frame(width: columnWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func bar(_ load: DayLoad, maxTotal: Int, past: Bool) -> some View {
        if load.total > 0 {
            let height = max(8, CGFloat(load.total) / CGFloat(maxTotal) * maxBarHeight)
            let gaps = CGFloat(max(0, load.segments.count - 1)) * 1.5
            let inner = max(height - gaps, CGFloat(load.segments.count) * 3)
            VStack(spacing: 1.5) {
                ForEach(Array(load.segments.enumerated()), id: \.offset) { _, seg in
                    Group {
                        if let tone = p.eventPastel(key: seg.key) {
                            past ? GrooveboxScene.ground.mix(with: tone, by: 0.45) : tone
                        } else {
                            ChannelColor.gradient(for: seg.key, in: channelOrder)
                        }
                    }
                    .frame(height: max(3, inner * CGFloat(seg.count) / CGFloat(load.total)))
                }
            }
            .frame(width: barWidth)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
    }

    private func weekdayLetter(_ day: Date) -> String {
        let i = cal.component(.weekday, from: day) - 1
        let syms = cal.veryShortWeekdaySymbols
        return syms.indices.contains(i) ? syms[i] : ""
    }
}

/// Event detail — title, when, where, organizer, notes, and (for invites) RSVP.
struct EventDetailSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var engine: EngineModel
    let event: CalendarEvent
    @State private var rsvp: String?       // last-sent response (optimistic)
    @State private var rsvpError = false   // provider write-back failed
    @State private var sending = false
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?   // provider delete failed — surfaced in an alert
    // Observed so cancelling/restoring this meeting's alarm re-renders the row.
    @ObservedObject private var alarms = MeetingAlarms.shared
    private var p: ThemePalette { theme.palette }

    /// The alarm row only makes sense for a timed meeting that hasn't started.
    private var alarmApplies: Bool {
        alarms.enabled && !event.allDay && (event.start ?? .distantPast) > Date()
    }

    private var dayLabel: String {
        DayHeader.label(event.dayKey)
    }

    /// Someone else's meeting: RSVP, and no Edit — the organizer owns it (the
    /// provider refuses an attendee's changes). Your own event has an organizer
    /// too (you), so "has an organizer" alone offered RSVP on it.
    private var isInvite: Bool { engine.isInvite(event) }

    /// The provider-side response already on record for this account — our own
    /// attendee row, matched by the account's address. `needsAction` shows as
    /// no selection.
    private var providerRsvp: String? {
        guard let me = engine.accounts.first(where: { $0.id == event.accountKey })?.email.lowercased(),
              !me.isEmpty else { return nil }
        let status = event.attendees.first { ($0.email ?? "").lowercased() == me }?.responseStatus
        return status == "needsAction" ? nil : status
    }

    /// What the buttons reflect — the optimistic pick, else the synced provider state.
    private var currentRsvp: String? { rsvp ?? providerRsvp }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text(event.title).font(AppFont.xl).foregroundStyle(p.textPrimary)

                    if let meeting = event.meeting { joinButton(meeting) }

                    detailRow("clock", "\(dayLabel) · \(event.rangeLabel)")
                    if let loc = event.location, !loc.isEmpty { linkRow("mappin.and.ellipse", loc) }
                    if let org = event.organizerLabel { detailRow("person.crop.circle", org) }
                    if let cal = event.calendarName, !cal.isEmpty { detailRow("calendar", cal) }
                    if alarmApplies { alarmRow }
                    // Zones need a cloud session; a prep block only makes sense ahead
                    // of a timed meeting.
                    if ZoneStore.shared.enabled, !event.allDay, let start = event.start, start > Date() {
                        PrepZoneRow(title: event.title, eventId: event.id, meetingStart: start)
                    }

                    if isInvite {
                        Divider().overlay(p.borderDefault)
                        rsvpSection
                    }

                    let attendees = event.attendees
                    if !attendees.isEmpty {
                        Divider().overlay(p.borderDefault)
                        attendeesSection(attendees)
                    }

                    if let notes = event.detail, !notes.isEmpty {
                        Divider().overlay(p.borderDefault)
                        Text(Linkify.attributed(notes, color: p.accentViolet))
                            .font(AppFont.sm).foregroundStyle(p.textSecondary).tint(p.accentViolet)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Space.s4)
            }
            .background(p.bgBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(p.accentViolet)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Edit/Delete only on calendars the user can write to — read-only
                    // calendars (shared / subscribed / holidays) 403 on the provider.
                    if event.calendarWritable {
                        Menu {
                            if !isInvite {
                                Button { showEdit = true } label: { Label("Edit", systemImage: "pencil") }
                            }
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Label("Delete event", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(AppFont.lg)
                                .foregroundStyle(LinearGradient(colors: p.ringColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                        .disabled(deleting)
                    }
                }
            }
            .sheet(isPresented: $showEdit) {
                NewEventSheet(initialDay: event.dayKey, editing: event)
            }
            .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
                if engine.isInvite(event) {
                    Button("Decline & delete", role: .destructive) { deleteEvent(decline: true) }
                    Button("Delete only") { deleteEvent(decline: false) }
                } else {
                    Button("Delete event", role: .destructive) { deleteEvent(decline: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if engine.isInvite(event) {
                    Text("Let \(event.organizerLabel ?? "the organizer") know you won't attend?")
                } else {
                    Text("\(event.title) will be removed from your calendar.")
                }
            }
            .alert("Couldn't delete event", isPresented: Binding(
                get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
    }

    private func deleteEvent(decline: Bool) {
        deleting = true
        Task {
            let result = await engine.deleteCalendarEvent(event, decline: decline)
            await MainActor.run {
                deleting = false
                if result.ok { dismiss() } else { deleteError = result.error }
            }
        }
    }

    /// The pre-scheduled alarm for this one meeting — and the escape hatch when it
    /// gets called off in real life but stays on the calendar.
    private var alarmRow: some View {
        let muted = alarms.isMuted(event.id)
        return Button {
            alarms.setMuted(!muted, eventKey: event.id, engine: engine)
        } label: {
            HStack(alignment: .center, spacing: Space.s3) {
                Image(systemName: muted ? "bell.slash" : "bell.badge")
                    .font(AppFont.base)
                    .foregroundStyle(muted ? p.textTertiary : p.accentViolet).frame(width: 22)
                Text(muted ? "Alarm cancelled" : "Alarm \(alarms.leadMinutes) min before")
                    .font(AppFont.sm).foregroundStyle(muted ? p.textTertiary : p.textPrimary)
                Spacer(minLength: 0)
                Text(muted ? "Restore" : "Cancel")
                    .font(AppFont.xs(.semibold)).foregroundStyle(p.accentViolet)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rsvpSection: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Going?").font(AppFont.xs(.semibold)).foregroundStyle(p.textSecondary)
            HStack(spacing: Space.s2) {
                rsvpButton("Yes", value: "accepted", icon: "checkmark.circle.fill", tint: p.accentSuccess)
                rsvpButton("Maybe", value: "tentative", icon: "questionmark.circle.fill", tint: p.accentWarning)
                rsvpButton("No", value: "declined", icon: "xmark.circle.fill", tint: p.accentDanger)
            }
            if rsvpError {
                Text("Couldn't send your response. Try again.")
                    .font(AppFont.xs2).foregroundStyle(p.accentDanger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Native capsule buttons, like the nav-bar Done pill: neutral bordered chrome
    /// with the action color carried by the icon+label; the chosen one fills solid.
    @ViewBuilder
    private func rsvpButton(_ label: String, value: String, icon: String, tint: Color) -> some View {
        let chosen = currentRsvp == value
        let content = HStack(spacing: 5) {
            Image(systemName: icon).font(AppFont.sm)
            Text(label).font(AppFont.sm(.semibold))
        }
        .frame(maxWidth: .infinity)
        if p.selectKeycap != nil {
            // Groovebox: the chosen answer is the cream keycap, the others dark keycaps.
            let role: KeycapRole = chosen ? .selected : .secondary
            Button { sendRsvp(value) } label: {
                content.foregroundStyle(chosen ? p.keycapLabel(.selected, or: tint) : tint)
                    .padding(.vertical, 8)
                    .keycapSurface(role, radius: Radius.full)
            }
            .buttonStyle(.plain)
            .disabled(sending)
        } else if chosen {
            Button { sendRsvp(value) } label: { content.foregroundStyle(.white) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(tint)
                .disabled(sending)
        } else {
            Button { sendRsvp(value) } label: { content.foregroundStyle(tint) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(Color(.systemGray))
                .disabled(sending)
        }
    }

    private func sendRsvp(_ value: String) {
        let previous = rsvp
        rsvp = value
        rsvpError = false
        sending = true
        Task {
            let result = await engine.respondToEvent(accountKey: event.accountKey, eventKey: event.id, response: value)
            await MainActor.run {
                sending = false
                if !result.ok { rsvp = previous; rsvpError = true }
            }
        }
    }

    /// One tap into the call — the mirror of the desktop event popup's Join button.
    @ViewBuilder
    private func joinButton(_ meeting: EventMeeting) -> some View {
        let label = HStack(spacing: 6) {
            if let logo = meeting.logo, let ui = BundledImage.named(logo) {
                Image(uiImage: ui).resizable().scaledToFit().frame(width: 16, height: 16)
            } else {
                Image(systemName: "video.fill").font(AppFont.sm)
            }
            Text("Join \(meeting.label)").font(AppFont.sm(.semibold))
        }
        if p.primaryKeycap != nil {
            // Groovebox: the lavender dome.
            Button { openURL(meeting.url) } label: {
                label.foregroundStyle(p.keycapLabel(.primary, or: .white))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .keycapSurface(.primary, radius: Radius.full)
            }
            .buttonStyle(.plain)
        } else {
            Button { openURL(meeting.url) } label: { label.foregroundStyle(.white) }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(p.accentViolet)
        }
    }

    private func detailRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: icon).font(AppFont.base).foregroundStyle(p.accentViolet).frame(width: 22)
            Text(text).font(AppFont.sm).foregroundStyle(p.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Same as `detailRow` but linkifies bare URLs (used for location, which is
    /// often a Meet/Zoom link).
    private func linkRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: icon).font(AppFont.base).foregroundStyle(p.accentViolet).frame(width: 22)
            Text(Linkify.attributed(text, color: p.accentViolet))
                .font(AppFont.sm).foregroundStyle(p.textPrimary).tint(p.accentViolet)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func attendeesSection(_ attendees: [EventAttendee]) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("\(attendees.count) \(attendees.count == 1 ? "participant" : "participants")")
                .font(AppFont.xs(.semibold)).foregroundStyle(p.textSecondary)
            ForEach(Array(attendees.enumerated()), id: \.offset) { _, person in
                HStack(alignment: .center, spacing: Space.s3) {
                    Image(systemName: person.statusIcon)
                        .font(AppFont.base).foregroundStyle(statusTint(person.responseStatus)).frame(width: 22)
                    Text(person.displayName).font(AppFont.sm).foregroundStyle(p.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    if person.isOrganizer {
                        Text("Organizer").font(AppFont.xs3(.semibold)).foregroundStyle(p.textSecondary)
                            .padding(.horizontal, Space.s2).padding(.vertical, 2)
                            .background(p.bgRaised, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// RSVP-state tint, matching the Going? buttons.
    private func statusTint(_ status: String?) -> Color {
        switch status {
        case "accepted":  return p.accentSuccess
        case "declined":  return p.accentDanger
        case "tentative": return p.accentWarning
        default:          return p.textTertiary
        }
    }
}

/// New event — title, calendar, time window, location → an `EventDraft` JSON the
/// engine writes through to the provider. Calendars come from the local store
/// (provider id + account key are what the create FFI needs).
struct NewEventSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var chrome: ChromeModel
    /// The calendar last created on — the default when the inbox isn't filtered.
    @AppStorage("calendar.lastCreateCalendarId") private var lastCalendarId = ""
    private var p: ThemePalette { theme.palette }

    let initialDay: Date
    /// When set, the sheet edits this event (provider write-through) instead of creating.
    let editing: CalendarEvent?

    @State private var title = ""
    @State private var location = ""
    @State private var allDay = false
    @State private var start: Date
    @State private var end: Date
    /// Comma-separated attendee emails (prefilled when drafted by the Bridge).
    @State private var attendees = ""
    /// The guest list the edit opened with: it goes back to the provider only
    /// if it changed, so untouched guests keep their RSVPs.
    private var initialAttendees = ""
    @State private var calendar: WritableCalendar?
    @State private var calendars: [WritableCalendar] = []
    @State private var saving = false
    @State private var error: String?
    @State private var repeatRule = RepeatRule()
    /// What the sheet opened with: an edited series' own rule (read off the
    /// provider), so an untouched repeat isn't rewritten.
    @State private var initialRepeat = RepeatRule()
    /// The edited event is one instance of a series; Save asks which part.
    @State private var isSeries = false
    @State private var loadingRule = false
    /// The rule couldn't be read: whether this is a series is unknown, so the
    /// repeat can't be changed and Save edits this one event only.
    @State private var ruleUnknown = false
    @State private var askScope = false

    private var isEditing: Bool { editing != nil }
    private var repeatTouched: Bool { repeatRule != initialRepeat }

    /// `initialStart`/`initialEnd` pre-fill a new event (the day view's drag-to-create).
    init(initialDay: Date, editing: CalendarEvent? = nil, initialStart: Date? = nil, initialEnd: Date? = nil) {
        self.initialDay = initialDay
        self.editing = editing
        if let ev = editing {
            _title = State(initialValue: ev.title)
            _location = State(initialValue: ev.location ?? "")
            _allDay = State(initialValue: ev.allDay)
            let s = ev.start ?? initialDay
            _start = State(initialValue: s)
            _end = State(initialValue: ev.end ?? s)
            // The guests, so an edit shows them and sends them back unchanged
            // (the organizer is on the list but isn't a guest).
            let guests = ev.attendees.filter { !$0.isOrganizer }.compactMap(\.email).joined(separator: ", ")
            _attendees = State(initialValue: guests)
            initialAttendees = guests
        } else if let s = initialStart, let e = initialEnd, e > s {
            _start = State(initialValue: s)
            _end = State(initialValue: e)
        } else {
            // Default to the next top-of-hour on the chosen day, 1h long.
            let cal = Calendar.current
            let base = cal.date(bySettingHour: max(cal.component(.hour, from: Date()) + 1, 9),
                                minute: 0, second: 0, of: initialDay) ?? initialDay
            _start = State(initialValue: base)
            _end = State(initialValue: cal.date(byAdding: .hour, value: 1, to: base) ?? base)
        }
    }

    /// Create from a Bridge-drafted meeting (title/time/location/attendees prefilled).
    init(seed: EventDraftSeed) {
        self.initialDay = seed.start
        self.editing = nil
        _title = State(initialValue: seed.title)
        _location = State(initialValue: seed.location)
        _start = State(initialValue: seed.start)
        _end = State(initialValue: seed.end)
        _attendees = State(initialValue: seed.attendees.joined(separator: ", "))
        initialAttendees = ""
    }

    private static let dayOnly: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        return f
    }()

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && (isEditing || calendar != nil) && end >= start && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    if isEditing {
                        // The event stays on its own calendar; show it read-only.
                        if let name = editing?.calendarName, !name.isEmpty {
                            HStack { Text("Calendar"); Spacer(); Text(name).foregroundStyle(p.textTertiary) }
                        }
                    } else if calendars.count > 1 {
                        Picker("Calendar", selection: $calendar) {
                            ForEach(calendars) { Text($0.name).tag(Optional($0)) }
                        }
                    } else if let c = calendar {
                        HStack { Text("Calendar"); Spacer(); Text(c.name).foregroundStyle(p.textTertiary) }
                    }
                }
                Section {
                    Toggle("All-day", isOn: $allDay).tint(p.toggle)
                    DatePicker("Starts", selection: $start,
                               displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                        // Moving the start drags the end with it, keeping the
                        // meeting's length — every other calendar app does this,
                        // and without it changing the start alone leaves an end
                        // before it, which the providers reject.
                        .onChange(of: start) { old, new in
                            let length = max(end.timeIntervalSince(old), 0)
                            end = new.addingTimeInterval(length > 0 ? length : 3600)
                        }
                    DatePicker("Ends", selection: $end,
                               displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                }
                repeatSection

                Section {
                    TextField("Location", text: $location)
                        .textInputAutocapitalization(.words)
                } header: { Text("Where") }

                Section {
                    TextField("Attendee emails, separated by commas", text: $attendees)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                } header: { Text("With") }

                if let error {
                    Section { Text(error).font(AppFont.sm).foregroundStyle(p.accentDanger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit event" : "New event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(p.accentViolet)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The write is a round trip to Google/Graph plus a resync, so
                    // it is not instant; without the spinner the button just goes
                    // grey and the sheet looks stuck.
                    if saving {
                        ProgressView().controlSize(.small).tint(p.accentViolet)
                    } else {
                        Button(isEditing ? "Save" : "Add") {
                            if isSeries { askScope = true } else { save(scope: nil) }
                        }.disabled(!canSave || loadingRule)
                            .foregroundStyle(canSave ? p.accentViolet : p.textTertiary)
                    }
                }
            }
            // Google/Outlook's question for an edited repeating event. A new
            // rule is a series change, so "This event" isn't offered with one.
            .confirmationDialog("Save recurring event", isPresented: $askScope, titleVisibility: .visible) {
                if !repeatTouched { Button("This event") { save(scope: "this") } }
                Button("This and following events") { save(scope: "following") }
                Button("All events") { save(scope: "all") }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                if editing != nil {
                    await loadRule()
                    return
                }
                calendars = await engine.store.read { $0.writableCalendars() }
                // The account the inbox is filtered to (its primary sorts first) →
                // the calendar last created on → the first.
                if calendar == nil {
                    calendar = calendars.first { $0.accountKey == chrome.inboxAccountKey }
                        ?? calendars.first { $0.id == lastCalendarId }
                        ?? calendars.first
                }
            }
        }
    }

    /// Synced rows are expanded instances; an edited event's rule lives on the provider.
    private func loadRule() async {
        guard let ev = editing else { return }
        loadingRule = true
        ruleUnknown = false
        switch await engine.calendarSeriesRule(accountKey: ev.accountKey, eventKey: ev.id) {
        case .success(let rule?):
            initialRepeat = RepeatRule(rrule: rule, start: start)
            repeatRule = initialRepeat
            isSeries = true
        case .success(nil):
            isSeries = false
        case .failure:
            // Unknown is not "a series": Save must edit this one event, as
            // the sheet says, even if an earlier read had found a rule.
            ruleUnknown = true
            isSeries = false
            initialRepeat = RepeatRule()
            repeatRule = initialRepeat
        }
        loadingRule = false
    }

    @ViewBuilder private var repeatSection: some View {
        Section {
            if loadingRule {
                HStack { Text("Repeat"); Spacer(); ProgressView().controlSize(.small) }
            } else if ruleUnknown {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't read this event's repeat. Saving now changes this event only.")
                        .font(AppFont.sm).foregroundStyle(p.textTertiary)
                    Button("Try again") { Task { await loadRule() } }.foregroundStyle(p.accentViolet)
                }
            } else {
                Picker("Repeat", selection: $repeatRule.freq) {
                    ForEach(RepeatRule.Freq.allCases.filter { $0 != .custom || initialRepeat.freq == .custom }) {
                        Text($0.label).tag($0)
                    }
                }
                .onChange(of: repeatRule.freq) { _, f in
                    // Back to "custom" restores the rule as it was set elsewhere.
                    if f == .custom { repeatRule = initialRepeat }
                }
                if repeatRule.freq != .none && repeatRule.freq != .custom {
                    Stepper(value: $repeatRule.interval, in: 1...99) {
                        Text(repeatRule.interval == 1 ? "Every \(repeatRule.freq.unit)" : "Every \(repeatRule.interval) \(repeatRule.freq.unit)s")
                    }
                    if repeatRule.freq == .weekly { weekdayRow }
                    Picker("Ends", selection: $repeatRule.ends) {
                        ForEach(RepeatRule.Ends.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: repeatRule.ends) { _, e in
                        // "On date" opens on the start's day, never before it.
                        let first = Calendar.current.startOfDay(for: start)
                        if e == .on && repeatRule.until < first { repeatRule.until = first }
                    }
                    if repeatRule.ends == .on {
                        DatePicker("Until", selection: $repeatRule.until, in: start..., displayedComponents: [.date])
                    } else if repeatRule.ends == .after {
                        Stepper(value: $repeatRule.count, in: 1...999) {
                            Text(repeatRule.count == 1 ? "1 time" : "\(repeatRule.count) times")
                        }
                    }
                }
            }
        }
    }

    /// M T W T F S S toggles; none ticked = the start's own weekday.
    private var weekdayRow: some View {
        let active = repeatRule.activeDays(start: start)
        return HStack(spacing: 6) {
            ForEach(RepeatRule.weekdays, id: \.code) { day in
                let on = active.contains(day.code)
                Button {
                    var next = active
                    if on { next.remove(day.code) } else { next.insert(day.code) }
                    repeatRule.days = next
                } label: {
                    Text(day.short)
                        .font(AppFont.sm)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(on ? p.accentViolet.opacity(0.28) : Color.clear))
                        .overlay(Circle().stroke(on ? p.accentViolet : p.textTertiary.opacity(0.4), lineWidth: 1))
                        .foregroundStyle(on ? p.textPrimary : p.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day.weekday - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// `scope` is nil for a one-off or a new event, else this / following / all.
    private func save(scope: String?) {
        // Create needs a target calendar; edit resolves it from the event key.
        guard isEditing || calendar != nil else { return }
        saving = true
        error = nil
        var draft: [String: Any] = [
            "title": title.trimmingCharacters(in: .whitespaces),
            "all_day": allDay,
            "timezone": TimeZone.current.identifier,
        ]
        if allDay {
            draft["start_at"] = Self.dayOnly.string(from: start)
            // All-day end is EXCLUSIVE on both providers, so a one-day event ends
            // on the following date. Sending the same date twice is a zero-length
            // event, which Google and Graph both reject — and before the error
            // was shown, that read as "I added it and it went nowhere".
            let lastDay = max(end, start)
            let exclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
            draft["end_at"] = Self.dayOnly.string(from: exclusiveEnd)
        } else {
            draft["start_at"] = isoLocalInternet.string(from: start)
            draft["end_at"] = isoLocalInternet.string(from: max(end, start))
        }
        let loc = location.trimmingCharacters(in: .whitespaces)
        if !loc.isEmpty { draft["location"] = loc }
        let split = { (text: String) in
            text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let people = split(attendees)
        if !isEditing {
            if !people.isEmpty { draft["attendees"] = people }
        } else if Set(people.map { $0.lowercased() }) != Set(split(initialAttendees).map { $0.lowercased() }) {
            // Changed: the new list, or the explicit "remove everyone" (an
            // empty list on its own means "unchanged" to the engine).
            if people.isEmpty { draft["attendees_cleared"] = true } else { draft["attendees"] = people }
        }
        // The rule: always on a series-wide edit (the engine reads its absence
        // there as "no longer repeats"), on a create or one-off only when set.
        let rule = repeatRule.rrule(start: start, allDay: allDay)
        if let scope { draft["scope"] = scope }
        if scope == "all" || scope == "following" || (scope == nil && (!isEditing || repeatTouched)) {
            if let rule { draft["recurrence"] = rule }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: draft),
              let json = String(data: data, encoding: .utf8) else {
            error = "Couldn't save the event."; saving = false; return
        }
        Task {
            let result: (ok: Bool, value: String)
            if let ev = editing {
                result = await engine.updateCalendarEvent(
                    accountKey: ev.accountKey, eventKey: ev.id, draftJSON: json)
            } else if let cal = calendar {
                result = await engine.createCalendarEvent(
                    accountKey: cal.accountKey, calendarProviderId: cal.providerId, draftJSON: json)
                if result.ok { lastCalendarId = cal.id }
            } else {
                result = (false, "no calendar")
            }
            await MainActor.run {
                saving = false
                if result.ok { dismiss() }
                // Show what the provider actually said. A bare "failed" reads as
                // a glitch and the sheet gets dismissed as if it had saved — the
                // event is then nowhere, with nothing to explain why.
                else { error = (isEditing ? "Couldn't update the event: " : "Couldn't create the event: ") + result.value }
            }
        }
    }
}
