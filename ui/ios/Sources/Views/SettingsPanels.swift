import SwiftUI
import OSLog
import UIKit

/// App logs — an in-app viewer of the unified log for this process (com.inbox2.*).
/// One parsed log entry — time, level, tag (subsystem category) and message, so the
/// viewer can colorize like the desktop LogViewer.
struct LogLine: Identifiable {
    let id = UUID()
    let time: String
    let level: String   // ERROR / WARN / INFO / DEBUG
    let tag: String
    let message: String
}

struct AppLogsPanel: View {
    @Environment(\.theme) private var theme
    @State private var logs: [LogLine] = []
    @State private var loading = true
    @State private var copied = false
    private var p: ThemePalette { theme.palette }

    var body: some View {
        SettingsScaffold(title: "App logs") {
            HStack(spacing: Space.s4) {
                Text("RECENT").font(AppFont.section(12, .semibold)).tracking(0.8).foregroundStyle(p.textTertiary)
                Spacer()
                Button { copy() } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(AppFont.sm(.semibold))
                        .foregroundStyle(copied ? p.accentTeal : p.accentViolet)
                }
                .disabled(logs.isEmpty)
                Button { load() } label: { Image(systemName: "arrow.clockwise").font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet) }
            }
            .padding(.horizontal, Space.s5).padding(.top, Space.s5).padding(.bottom, Space.s2)

            if loading {
                HStack(spacing: Space.s2) { ProgressView(); Text("Reading logs…").foregroundStyle(p.textSecondary) }
                    .padding(.horizontal, Space.s5)
            } else if logs.isEmpty {
                Text("No recent logs.").font(AppFont.sm).foregroundStyle(p.textTertiary).padding(.horizontal, Space.s5)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(logs) { entry in
                        line(entry)
                            .font(AppFont.mono(11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, Space.s5)
                .settingsGroup()
            }
        }
        .task { load() }
    }

    /// Desktop-style colored line: muted time, bold level (level color), teal tag,
    /// secondary message — concatenated so it wraps naturally.
    private func line(_ e: LogLine) -> Text {
        Text(e.time + " ").foregroundColor(p.textMuted)
        + Text(e.level).foregroundColor(levelColor(e.level)).bold()
        + Text("  ")
        + (e.tag.isEmpty ? Text("") : Text("[\(e.tag)] ").foregroundColor(p.accentTeal))
        + Text(e.message).foregroundColor(p.textSecondary)
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "ERROR": return p.statusDangerText
        case "WARN":  return p.statusWarnText
        case "DEBUG": return p.statusDebugText
        default:      return p.statusInfoText
        }
    }

    private nonisolated static func level(for e: OSLogEntryLog) -> String {
        switch e.level {
        case .error, .fault: return "ERROR"
        case .debug: return "DEBUG"
        case .info, .notice:
            return e.composedMessage.lowercased().contains("warn") ? "WARN" : "INFO"
        default: return "INFO"
        }
    }

    /// Copy the whole visible log to the clipboard as plain text (one line each,
    /// matching the on-screen "time LEVEL [tag] message" layout), then flash a tick.
    private func copy() {
        let text = logs.map { e in
            let tag = e.tag.isEmpty ? "" : "[\(e.tag)] "
            return "\(e.time) \(e.level)  \(tag)\(e.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
    }

    private func load() {
        loading = true
        Task.detached {
            var collected: [LogLine] = []
            let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm:ss"
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let entries = try store.getEntries()
                    .compactMap { $0 as? OSLogEntryLog }
                    .filter { $0.subsystem.hasPrefix("com.inbox2") }
                // Newest first, so the most recent activity is at the top of the panel.
                collected = entries.suffix(250).reversed().map { e in
                    LogLine(time: timeFmt.string(from: e.date),
                            level: Self.level(for: e),
                            tag: e.category,
                            message: e.composedMessage)
                }
            } catch {
                collected = [LogLine(time: "", level: "ERROR", tag: "",
                                     message: "Couldn't read logs: \(error.localizedDescription)")]
            }
            let result = collected
            await MainActor.run { logs = result; loading = false }
        }
    }
}

/// Dev mode — diagnostics + the component style guide.
struct DevModePanel: View {
    @Environment(\.theme) private var theme
    private var p: ThemePalette { theme.palette }
    var body: some View {
        SettingsScaffold(title: "Dev mode") {
            SettingsHeader(text: "Developer")
            VStack(spacing: 0) {
                NavigationLink { StyleGuideView() } label: { SettingsMenuRow(icon: "paintpalette", title: "Style guide") }.buttonStyle(.plain)
                SettingsDivider()
                NavigationLink { RootView() } label: { SettingsMenuRow(icon: "gauge.with.dots.needle.50percent", title: "Engine diagnostics") }.buttonStyle(.plain)
                SettingsDivider()
                NavigationLink { PromptTemplatesView() } label: { SettingsMenuRow(icon: "text.quote", title: "Prompt templates") }.buttonStyle(.plain)
            }
            .settingsGroup()

            SettingsHeader(text: "About")
            HStack {
                Text("Version").font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                Spacer()
                Text("0.1 (1)").font(AppFont.body).foregroundStyle(p.textTertiary)
            }
            .padding(.horizontal, Space.s5).frame(minHeight: 52)
            .settingsGroup()
        }
    }
}

/// Create or edit a built-in auto-rule: one or more AND-ed conditions
/// (field/op/value, incl. the `has_attachment` bool) → a built-in action.
/// Constructs the same conditions/action JSON the desktop writes and hands it to
/// `engine.createBuiltinRule` / `updateBuiltinRule`. Run-agent rules are
/// desktop-only and not offered here. Field/op/action values mirror the core rules
/// engine — see `core/src/rules/{conditions,actions}.rs`.
struct NewRuleSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: EngineModel
    private var p: ThemePalette { theme.palette }

    /// When set, the sheet edits this rule instead of creating a new one.
    let editing: LocalRule?

    @State private var name: String
    @State private var conditions: [RuleCondition]
    @State private var action: RuleActionChoice
    @State private var saving = false
    @State private var error: String?

    private var isEditing: Bool { editing != nil }

    init(editing: LocalRule? = nil) {
        self.editing = editing
        let parsed = Self.parse(editing)
        _name = State(initialValue: editing?.name ?? "")
        _conditions = State(initialValue: parsed.conditions)
        _action = State(initialValue: parsed.action)
    }

    /// Decode a stored rule's conditions + action back into the form's models.
    private static func parse(_ rule: LocalRule?) -> (conditions: [RuleCondition], action: RuleActionChoice) {
        var conditions: [RuleCondition] = []
        var action: RuleActionChoice = .archive
        guard let rule else { return ([RuleCondition()], action) }
        if let data = rule.conditionsJSON.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            conditions = arr.compactMap { c in
                guard let f = c["field"] as? String, let rf = RuleField(rawValue: f) else { return nil }
                let op = (c["op"] as? String).flatMap(RuleOp.init(rawValue:)) ?? (rf.isBool ? .isTrue : .contains)
                return RuleCondition(field: rf, op: op, value: "\(c["value"] ?? "")")
            }
        }
        if conditions.isEmpty { conditions = [RuleCondition()] }
        if let data = rule.actionJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch (obj["builtin"] as? String, obj["quadrant"] as? String) {
            case ("archive", _): action = .archive
            case ("mark_read", _): action = .markRead
            case ("auto_triage", Quadrant.doFirst.rawValue): action = .priority
            case ("auto_triage", Quadrant.schedule.rawValue): action = .schedule
            case ("auto_triage", Quadrant.delegate.rawValue): action = .delegate
            case ("auto_triage", Quadrant.later.rawValue): action = .later
            default: break
            }
        }
        return (conditions, action)
    }

    /// Condition fields the core engine matches (`from|to|subject|body|has_attachment`).
    enum RuleField: String, CaseIterable, Identifiable {
        case from, to, subject, body
        case hasAttachment = "has_attachment"
        var id: String { rawValue }
        var label: String { self == .hasAttachment ? "Has attachment" : rawValue.capitalized }
        /// Boolean fields take is_true/is_false and no value.
        var isBool: Bool { self == .hasAttachment }
    }
    /// Operators: text (`contains|equals|starts_with|ends_with`) + bool (`is_true|is_false`).
    enum RuleOp: String, CaseIterable, Identifiable {
        case contains, equals
        case startsWith = "starts_with"
        case endsWith = "ends_with"
        case isTrue = "is_true"
        case isFalse = "is_false"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .contains: return "contains"
            case .equals: return "is exactly"
            case .startsWith: return "starts with"
            case .endsWith: return "ends with"
            case .isTrue: return "is present"
            case .isFalse: return "is absent"
            }
        }
        static let textOps: [RuleOp] = [.contains, .equals, .startsWith, .endsWith]
        static let boolOps: [RuleOp] = [.isTrue, .isFalse]
    }

    /// One editable condition row. `value` is unused for bool fields.
    struct RuleCondition: Identifiable {
        let id = UUID()
        var field: RuleField = .from
        var op: RuleOp = .contains
        var value: String = ""
    }
    /// Built-in actions runnable on-device. Triage maps to `auto_triage` + a fixed
    /// quadrant; the rest are simple `perform_action` built-ins.
    enum RuleActionChoice: String, CaseIterable, Identifiable {
        case archive, markRead, priority, schedule, delegate, later
        var id: String { rawValue }
        var label: String {
            switch self {
            case .archive: return "Archive"
            case .markRead: return "Mark as read"
            case .priority: return "Triage → Priority"
            case .schedule: return "Triage → Schedule"
            case .delegate: return "Triage → Delegate"
            case .later: return "Triage → Later"
            }
        }
        /// The `action` JSON object for this choice.
        var actionJSON: [String: String] {
            switch self {
            case .archive:  return ["type": "perform_action", "builtin": "archive"]
            case .markRead: return ["type": "perform_action", "builtin": "mark_read"]
            case .priority: return ["type": "perform_action", "builtin": "auto_triage", "quadrant": Quadrant.doFirst.rawValue]
            case .schedule: return ["type": "perform_action", "builtin": "auto_triage", "quadrant": Quadrant.schedule.rawValue]
            case .delegate: return ["type": "perform_action", "builtin": "auto_triage", "quadrant": Quadrant.delegate.rawValue]
            case .later:    return ["type": "perform_action", "builtin": "auto_triage", "quadrant": Quadrant.later.rawValue]
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving &&
        !conditions.isEmpty &&
        // Text conditions need a value; bool conditions are always complete.
        conditions.allSatisfy { $0.field.isBool || !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Rule name", text: $name)
                } header: { Text("Name") }

                Section {
                    ForEach($conditions) { $cond in
                        conditionRow($cond)
                    }
                    .onDelete { conditions.remove(atOffsets: $0) }
                    Button {
                        conditions.append(RuleCondition())
                    } label: {
                        Label("Add condition", systemImage: "plus.circle").foregroundStyle(p.accentViolet)
                    }
                } header: { Text("When a message matches all of…") } footer: {
                    Text("e.g. From contains \u{201C}newsletter@\u{201D} · Has attachment is present")
                }

                Section {
                    Picker("Action", selection: $action) {
                        ForEach(RuleActionChoice.allCases) { Text($0.label).tag($0) }
                    }
                } header: { Text("Then") }

                if let error {
                    Section { Text(error).font(AppFont.sm).foregroundStyle(p.accentDanger) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit rule" : "New rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(p.accentViolet)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.disabled(!canSave)
                        .foregroundStyle(canSave ? p.accentViolet : p.textTertiary)
                }
            }
        }
    }

    /// One condition row: field + op pickers, plus a value field for text fields.
    /// Switching to/from a bool field swaps the op set so the stored op stays valid.
    @ViewBuilder private func conditionRow(_ cond: Binding<RuleCondition>) -> some View {
        let ops = cond.wrappedValue.field.isBool ? RuleOp.boolOps : RuleOp.textOps
        VStack(spacing: Space.s1) {
            Picker("Field", selection: cond.field) {
                ForEach(RuleField.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: cond.wrappedValue.field) { _, newField in
                // Keep the op valid for the new field kind.
                if !(newField.isBool ? RuleOp.boolOps : RuleOp.textOps).contains(cond.wrappedValue.op) {
                    cond.wrappedValue.op = newField.isBool ? .isTrue : .contains
                }
            }
            Picker("Condition", selection: cond.op) {
                ForEach(ops) { Text($0.label).tag($0) }
            }
            if !cond.wrappedValue.field.isBool {
                TextField("Value", text: cond.value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        let condArray: [[String: String]] = conditions.map { c in
            [
                "field": c.field.rawValue, "op": c.op.rawValue,
                "value": c.field.isBool ? "" : c.value.trimmingCharacters(in: .whitespaces),
            ]
        }
        guard let condJSON = jsonString(condArray),
              let actJSON = jsonString(action.actionJSON) else {
            error = "Couldn't save the rule."
            saving = false
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task {
            let ok: Bool
            if let rule = editing {
                ok = await engine.updateBuiltinRule(
                    ruleKey: rule.key, name: trimmedName,
                    conditionsJSON: condJSON, actionJSON: actJSON)
            } else {
                ok = await engine.createBuiltinRule(
                    name: trimmedName, conditionsJSON: condJSON, actionJSON: actJSON,
                    accountKey: nil, enabled: true).ok
            }
            await MainActor.run {
                saving = false
                if ok { dismiss() }
                else { error = isEditing ? "Couldn't update the rule." : "Couldn't create the rule." }
            }
        }
    }

    private func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
