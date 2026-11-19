import SwiftUI

// Calendar-zone UI (docs/iOS-App.md "Zones"): the agenda container, the app-wide
// "You're in the zone" card, the create/edit sheet, and the event sheet's prep row.
// Colours come from `p.zone(category.color)` — a per-theme tone, never a hex off
// the wire.

/// "1:41 left" — hours:minutes, rounded up so the last minute doesn't read 0:00.
func zoneRemainingLabel(_ end: Date, now: Date) -> String {
    let mins = max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    return String(format: "%d:%02d left", mins / 60, mins % 60)
}

/// Zone fill: the tone at ~14% plus faint diagonal stripes, so a zone reads as
/// "soft, not booked" next to solid event rows.
struct ZoneFill: View {
    @Environment(\.theme) private var theme
    let tone: Color
    var radius: CGFloat = Radius.xl
    var hatch: Double = 0.07

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme.palette.solidChipInk != nil {
            // Groovebox: zones are solid pastel blocks (labels switch to the ink).
            shape.fill(tone)
        } else {
            hatched(shape)
        }
    }

    private func hatched(_ shape: RoundedRectangle) -> some View {
        shape.fill(tone.opacity(0.14))
            .overlay(
                Canvas { ctx, size in
                    var path = Path()
                    var x = -size.height
                    while x < size.width {
                        path.move(to: CGPoint(x: x, y: size.height))
                        path.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 10
                    }
                    ctx.stroke(path, with: .color(tone.opacity(hatch)), lineWidth: 4)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            )
    }
}

/// A zone in the day agenda: tinted container (category, name, time, note) wrapping
/// the events that start inside it. Active right now → stronger outline, a
/// "1:41 left" pill and a thin progress bar.
struct ZoneBlock<Content: View>: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = ZoneStore.shared
    let zone: CloudZone
    let onTap: () -> Void
    @ViewBuilder let content: Content
    private var p: ThemePalette { theme.palette }

    var body: some View {
        let cat = store.category(zone.categoryId)
        let tone = p.zone(cat?.color)
        let ink = p.solidChipInk
        let label = ink ?? tone.mix(with: p.textPrimary, by: 0.35)
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let active = zone.isActive(at: ctx.date)
            VStack(alignment: .leading, spacing: Space.s1) {
                Button(action: onTap) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(tone).frame(width: 7, height: 7)
                            Text((cat?.name ?? "Zone").uppercased())
                                .font(AppFont.xs3).tracking(0.6).foregroundStyle(label)
                            Spacer(minLength: Space.s2)
                            if active {
                                Text(zoneRemainingLabel(zone.end, now: ctx.date))
                                    .font(AppFont.xs3(.semibold)).monospacedDigit()
                                    .foregroundStyle(label)
                                    .padding(.horizontal, Space.s2).padding(.vertical, 2)
                                    .background(tone.opacity(0.22), in: Capsule())
                            }
                        }
                        Text(zone.name).font(AppFont.sm(.semibold)).foregroundStyle(ink ?? p.textPrimary).lineLimit(2)
                        Text("\(ZoneStore.clock.string(from: zone.start)) – \(ZoneStore.clock.string(from: zone.end))")
                            .font(AppFont.xs2).foregroundStyle(ink?.opacity(0.7) ?? p.textTertiary)
                        if let note = zone.note, !note.isEmpty {
                            Text(note).font(AppFont.xs2).foregroundStyle(ink?.opacity(0.8) ?? p.textSecondary).lineLimit(3)
                        }
                        if active {
                            ProgressView(value: min(1, max(0, ctx.date.timeIntervalSince(zone.start)
                                                           / max(1, zone.end.timeIntervalSince(zone.start)))))
                                .tint(ink ?? tone)
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                content
            }
            .padding(Space.s3)
            .background(ZoneFill(tone: tone))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                    .strokeBorder(tone.opacity(active ? 0.85 : 0.45), lineWidth: active ? 1.5 : 1)
            )
            .opacity(zone.end < ctx.date ? 0.5 : 1)
        }
    }
}

/// The sticky "You're in the zone" card over every tab once a notify-zone starts. It
/// outlives the zone ("Zone ended", no countdown) until Done dismisses it (and its
/// Live Activity) for good.
struct ZoneBanner: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var chrome: ChromeModel
    @ObservedObject private var store = ZoneStore.shared
    private var p: ThemePalette { theme.palette }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            if let zone = store.cardZone(at: ctx.date) { card(zone, ended: ctx.date >= zone.end) }
        }
    }

    private func card(_ zone: CloudZone, ended: Bool) -> some View {
        let cat = store.category(zone.categoryId)
        let tone = p.zone(cat?.color)
        let ink = p.solidChipInk
        let label = ink ?? tone.mix(with: p.textPrimary, by: 0.35)
        return VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                HStack(spacing: 5) {
                    Circle().fill(tone).frame(width: 7, height: 7)
                    Text((cat?.name ?? "Zone").uppercased()).font(AppFont.xs3).tracking(0.6)
                }
                .foregroundStyle(label)
                .padding(.horizontal, Space.s2).padding(.vertical, 3)
                .background(tone.opacity(0.2), in: Capsule())
                Text(ended ? "Zone ended" : "You're in the zone").font(AppFont.xs2).foregroundStyle(ink?.opacity(0.8) ?? p.textSecondary)
                Spacer(minLength: Space.s2)
                if !ended {
                    Text(timerInterval: zone.start...zone.end, countsDown: true)
                        .font(AppFont.base(.semibold)).monospacedDigit().foregroundStyle(label)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80, alignment: .trailing)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zone.name).font(AppFont.base(.semibold)).foregroundStyle(ink ?? p.textPrimary).lineLimit(1)
                    if let note = zone.note, !note.isEmpty {
                        Text(note).font(AppFont.xs2).foregroundStyle(ink?.opacity(0.8) ?? p.textSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: Space.s2)
                // Plain text links, not buttons — deliberately low-key.
                HStack(spacing: 0) {
                    textLink("Done") { withAnimation(.easeOut(duration: 0.2)) { store.dismiss(zone) } }
                    Text("·").foregroundStyle(ink?.opacity(0.6) ?? p.textTertiary)
                    textLink("Open calendar") { chrome.showCalendar = true }
                }
                .font(AppFont.xs(.medium))
            }
            Group {
                if ended {
                    ProgressView(value: 1)
                } else {
                    ProgressView(timerInterval: zone.start...zone.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                }
            }
            .tint(ink ?? tone)
        }
        .padding(Space.s3)
        // Opaque base under the tint — the card floats over arbitrary content.
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(p.floatFill ?? p.bgElevated)
                ZoneFill(tone: tone)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).strokeBorder(tone.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(p.isDark ? 0.4 : 0.12), radius: 12, y: 6)
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s1)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// A real Button (VoiceOver, 44pt target) that reads as tinted text.
    private func textLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(p.solidChipInk ?? p.textSecondary)
    }
}

/// Category chips: coloured dot + name; the picked one is filled and outlined.
struct ZoneCategoryChips: View {
    @Environment(\.theme) private var theme
    let categories: [CloudZoneCategory]
    @Binding var selection: String?
    private var p: ThemePalette { theme.palette }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(categories) { cat in
                    let tone = p.zone(cat.color)
                    let on = selection == cat.id
                    Button { selection = on ? nil : cat.id } label: {
                        HStack(spacing: 5) {
                            Circle().fill(tone).frame(width: 8, height: 8)
                            Text(cat.name).font(AppFont.xs(.medium))
                                .foregroundStyle(on ? (p.solidChipInk ?? tone.mix(with: p.textPrimary, by: 0.35)) : p.textSecondary)
                        }
                        .padding(.horizontal, Space.s3).padding(.vertical, 6)
                        // Groovebox: the chosen category is a solid pastel chip.
                        .background(on ? (p.solidChipInk != nil ? tone : tone.opacity(0.18)) : p.bgSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? tone.opacity(0.6) : p.borderDefault, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// New / edit zone — iOS grouped form over the API.
struct ZoneSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ZoneStore.shared
    let editing: CloudZone?

    @State private var name: String
    @State private var note: String
    @State private var categoryId: String?
    @State private var start: Date
    @State private var end: Date
    @State private var notify: Bool
    @State private var repeatRule: String
    @State private var hasUntil: Bool
    @State private var until: Date
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    private var p: ThemePalette { theme.palette }

    /// `initialStart`/`initialEnd` pre-fill a new zone (the day view's drag-to-create).
    init(initialDay: Date, editing: CloudZone? = nil, initialStart: Date? = nil, initialEnd: Date? = nil) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _note = State(initialValue: editing?.note ?? "")
        _categoryId = State(initialValue: editing?.categoryId)
        _notify = State(initialValue: editing?.notify ?? true)
        _repeatRule = State(initialValue: editing?.repeatRule ?? CloudZone.repeatNone)
        let untilDay = editing?.repeatUntil.flatMap { ZoneStore.day.date(from: $0) }
        _hasUntil = State(initialValue: untilDay != nil)
        _until = State(initialValue: untilDay ?? Calendar.current.date(byAdding: .month, value: 1, to: initialDay) ?? initialDay)
        if let z = editing {
            _start = State(initialValue: z.start)
            _end = State(initialValue: z.end)
        } else if let s = initialStart, let e = initialEnd, e > s, e.timeIntervalSince(s) <= 86_400 {
            _start = State(initialValue: s)
            _end = State(initialValue: e)
        } else {
            // Next top-of-hour on the chosen day, 2h — a focus block, not a meeting.
            let cal = Calendar.current
            let base = cal.date(bySettingHour: max(cal.component(.hour, from: Date()) + 1, 9),
                                minute: 0, second: 0, of: initialDay) ?? initialDay
            _start = State(initialValue: base)
            _end = State(initialValue: base.addingTimeInterval(2 * 3600))
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && end > start
            && end.timeIntervalSince(start) <= 86_400 && !saving
    }

    private static let repeats = [(CloudZone.repeatNone, "Never"), (CloudZone.repeatDaily, "Every day"),
                                  (CloudZone.repeatWeekdays, "Every weekday"), (CloudZone.repeatWeekly, "Every week")]

    /// The end is picked as a time of day: on the start's date, or the next day
    /// when it's at/before the start (an overnight zone) — so at most 24h.
    private var endTime: Binding<Date> {
        Binding(get: { end }, set: { picked in
            let cal = Calendar.current
            let hm = cal.dateComponents([.hour, .minute], from: picked)
            var e = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: start) ?? picked
            if e <= start { e = cal.date(byAdding: .day, value: 1, to: e) ?? e }
            end = e
        })
    }

    private var endsNextDay: Bool {
        !Calendar.current.isDate(end, inSameDayAs: start)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("What you'll work on", text: $note, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    ZoneCategoryChips(categories: store.categories, selection: $categoryId)
                    NavigationLink("Edit categories") { ZoneCategoriesView() }
                        .font(AppFont.sm).foregroundStyle(p.textSecondary)
                } header: { Text("Category") }
                Section {
                    DatePicker("Starts", selection: $start)
                        // Keep the length when the start moves, like the event sheet.
                        .onChange(of: start) { old, new in
                            let length = end.timeIntervalSince(old)
                            end = new.addingTimeInterval(length > 0 && length <= 86_400 ? length : 3600)
                        }
                    DatePicker(selection: endTime, displayedComponents: .hourAndMinute) {
                        HStack(spacing: Space.s2) {
                            Text("Ends")
                            if endsNextDay {
                                Text("next day").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                            }
                        }
                    }
                    Picker("Repeat", selection: $repeatRule) {
                        ForEach(Self.repeats, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .tint(p.textSecondary)
                    if repeatRule != CloudZone.repeatNone {
                        Toggle("Until", isOn: $hasUntil).tint(p.toggle)
                        if hasUntil {
                            DatePicker("Last day", selection: $until, in: start..., displayedComponents: .date)
                        }
                    }
                } footer: {
                    if editing?.isRepeating == true {
                        Text("This zone repeats. Changes apply to all repeats.")
                    }
                }
                Section {
                    Toggle("Zone alert", isOn: $notify).tint(p.toggle)
                } footer: {
                    Text("Zones never mark you busy. People can still book this time.")
                }
                if editing != nil {
                    Section {
                        Button(editing?.isRepeating == true ? "Delete all repeats" : "Delete zone", role: .destructive) {
                            confirmDelete = true
                        }
                    }
                }
                if let error {
                    Section { Text(error).font(AppFont.sm).foregroundStyle(p.accentDanger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle(editing == nil ? "New zone" : "Edit zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(p.accentViolet)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if saving {
                        ProgressView().controlSize(.small).tint(p.accentViolet)
                    } else {
                        Button(editing == nil ? "Add" : "Save") { save() }.disabled(!canSave)
                            .foregroundStyle(canSave ? p.accentViolet : p.textTertiary)
                    }
                }
            }
            .confirmationDialog(editing?.isRepeating == true ? "Delete every repeat of this zone?" : "Delete this zone?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(editing?.isRepeating == true ? "Delete all repeats" : "Delete zone", role: .destructive) { remove() }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                if store.categories.isEmpty { await store.loadCategories() }
                if editing == nil, categoryId == nil { categoryId = store.categories.first?.id }
            }
        }
    }

    private func save() {
        saving = true; error = nil
        Task {
            let repeating = repeatRule != CloudZone.repeatNone
            // Moving a prep zone by hand unhooks it from its meeting, or the next
            // reconcile would snap it back.
            let retimed = editing.map { $0.start != start || $0.end != end } ?? false
            let err = await store.save(editing: editing, name: name.trimmingCharacters(in: .whitespaces),
                                       note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                       categoryId: categoryId, start: start, end: end, notify: notify,
                                       repeatRule: repeatRule, repeatUntil: repeating && hasUntil ? until : nil,
                                       clearAnchor: retimed && editing?.anchorEventId != nil)
            saving = false
            if let err { error = "Couldn't save the zone: \(err)" } else { dismiss() }
        }
    }

    private func remove() {
        guard let zone = editing else { return }
        saving = true; error = nil
        Task {
            let err = await store.delete(zone)
            saving = false
            if let err { error = "Couldn't delete the zone: \(err)" } else { dismiss() }
        }
    }
}

/// EventDetailSheet's "Prep zone" row: 30 min / 1 hour / 2 hours before the meeting.
struct PrepZoneRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = ZoneStore.shared
    let title: String
    let eventId: String
    let meetingStart: Date
    @State private var minutes = 60
    @State private var saving = false
    @State private var added = false
    @State private var error: String?
    private var p: ThemePalette { theme.palette }
    private let options = [(30, "30 min"), (60, "1 hour"), (120, "2 hours")]

    private func addPrep() {
        saving = true; error = nil
        Task {
            if store.categories.isEmpty { await store.loadCategories() }
            error = await store.createPrep(title: title, eventId: eventId, meetingStart: meetingStart, minutes: minutes)
            saving = false
            added = error == nil
        }
    }

    var body: some View {
        let tone = p.zone(store.categories.first { $0.name.caseInsensitiveCompare("Prep") == .orderedSame }?.color ?? "amber")
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s3) {
                Image(systemName: "scope").font(AppFont.base).foregroundStyle(tone).frame(width: 22)
                Text("Prep zone").font(AppFont.sm).foregroundStyle(p.textPrimary)
            }
            HStack(spacing: Space.s2) {
                ForEach(options, id: \.0) { value, label in
                    let on = minutes == value
                    Button { minutes = value; added = false } label: {
                        Text(label).font(AppFont.xs(.medium))
                            .foregroundStyle(on ? p.keycapLabel(.selected, or: tone.mix(with: p.textPrimary, by: 0.35))
                                                : p.keycapLabel(.secondary, or: p.textSecondary))
                            .padding(.horizontal, Space.s3).padding(.vertical, 6)
                            .keycapSurface(on ? .selected : .secondary, radius: Radius.full) {
                                Capsule().fill(on ? tone.opacity(0.18) : p.bgSurface)
                                    .overlay(Capsule().strokeBorder(on ? tone.opacity(0.6) : p.borderDefault, lineWidth: 1))
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 22 + Space.s3)
            let addLabel = HStack(spacing: 6) {
                if saving { ProgressView().controlSize(.small) }
                Image(systemName: added ? "checkmark" : "plus")
                Text(added ? "Prep zone added" : "Add prep zone")
            }
            .font(AppFont.sm(.semibold))
            Group {
                if p.primaryKeycap != nil {
                    // Groovebox: the lavender dome, like every primary action.
                    Button(action: addPrep) {
                        addLabel.foregroundStyle(p.keycapLabel(.primary, or: tone))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .keycapSurface(.primary, radius: Radius.full)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: addPrep) { addLabel }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).tint(tone)
                }
            }
            .disabled(saving || added)
            .padding(.leading, 22 + Space.s3)
            if let error {
                Text(error).font(AppFont.xs2).foregroundStyle(p.accentDanger).padding(.leading, 22 + Space.s3)
            }
        }
    }
}

/// Zone categories: list with colour dot; add, rename, recolour (tap a row), delete
/// (swipe or long-press). Deleting leaves its zones uncategorised.
struct ZoneCategoriesView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = ZoneStore.shared
    @State private var editing: CloudZoneCategory?
    @State private var adding = false
    @State private var error: String?
    private var p: ThemePalette { theme.palette }

    var body: some View {
        List {
            Section {
                ForEach(store.categories) { cat in
                    Button { editing = cat } label: {
                        HStack(spacing: Space.s3) {
                            Circle().fill(p.zone(cat.color)).frame(width: 10, height: 10)
                            Text(cat.name).font(AppFont.base).foregroundStyle(p.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right").font(AppFont.xs2(.semibold)).foregroundStyle(p.textMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions { Button("Delete", role: .destructive) { remove(cat) } }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = cat }
                        Button("Delete", systemImage: "trash", role: .destructive) { remove(cat) }
                    }
                }
            } footer: {
                Text("Its zones stay but lose their colour.")
            }
            if let error {
                Section { Text(error).font(AppFont.sm).foregroundStyle(p.accentDanger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(p.bgBase.ignoresSafeArea())
        .navigationTitle("Zone categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }.foregroundStyle(p.accentViolet)
            }
        }
        .sheet(item: $editing) { ZoneCategorySheet(category: $0) }
        .sheet(isPresented: $adding) { ZoneCategorySheet(category: nil) }
        .task { if store.categories.isEmpty { await store.loadCategories() } }
    }

    private func remove(_ cat: CloudZoneCategory) {
        error = nil
        Task { if let err = await store.deleteCategory(cat.id) { error = "Couldn't delete: \(err)" } }
    }
}

/// Add / edit one category: a name and one of the six palette colours.
private struct ZoneCategorySheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ZoneStore.shared
    let category: CloudZoneCategory?
    @State private var name: String
    @State private var color: String
    @State private var saving = false
    @State private var error: String?
    private var p: ThemePalette { theme.palette }

    init(category: CloudZoneCategory?) {
        self.category = category
        _name = State(initialValue: category?.name ?? "")
        _color = State(initialValue: category?.color ?? ZoneStore.palette[0])
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) }
                Section {
                    HStack(spacing: Space.s3) {
                        ForEach(ZoneStore.palette, id: \.self) { key in
                            let tone = p.zone(key)
                            Button { color = key } label: {
                                Circle().fill(tone).frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(p.textPrimary.opacity(color == key ? 0.9 : 0), lineWidth: 2).padding(-4))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(key.capitalized)
                            .accessibilityAddTraits(color == key ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, Space.s2)
                } header: { Text("Colour") }
                if let error {
                    Section { Text(error).font(AppFont.sm).foregroundStyle(p.accentDanger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle(category == nil ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(p.accentViolet)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if saving {
                        ProgressView().controlSize(.small).tint(p.accentViolet)
                    } else {
                        Button(category == nil ? "Add" : "Save") { save() }.disabled(!canSave)
                            .foregroundStyle(canSave ? p.accentViolet : p.textTertiary)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        saving = true; error = nil
        Task {
            let err = await store.saveCategory(id: category?.id, name: name.trimmingCharacters(in: .whitespaces), color: color)
            saving = false
            if let err { error = "Couldn't save: \(err)" } else { dismiss() }
        }
    }
}
