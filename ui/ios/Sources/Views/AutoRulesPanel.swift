import SwiftUI

/// Auto rules — the real on-device rules. Toggle enable/disable inline; create
/// built-in rules here (run-agent rules are still authored on desktop).
struct AutoRulesPanel: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @State private var rules: [LocalRule] = []
    @State private var showNewRule = false
    @State private var editingRule: LocalRule?
    @State private var pendingDelete: LocalRule?
    private var p: ThemePalette { theme.palette }
    var body: some View {
        SettingsScaffold(title: "Auto rules", trailing: {
            SettingsAddButton { showNewRule = true }
        }) {
            if rules.isEmpty {
                SettingsInfo(icon: "line.3.horizontal.decrease", title: "No rules yet",
                    body0: "Rules act on new mail as it reaches this phone. Rules that run an agent need the desktop app.",
                    note: "Tap + above to add one, or create them on desktop.",
                    heroSymbol: "line.3.horizontal.decrease.circle")
            } else {
                SettingsHeader(text: "\(rules.count) rule\(rules.count == 1 ? "" : "s")")
                VStack(spacing: 0) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { i, rule in
                        HStack(alignment: .top, spacing: Space.s3) {
                            Button { toggle(rule) } label: {
                                Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                                    .font(AppFont.body).foregroundStyle(rule.enabled ? p.accentSuccess : p.textMuted).padding(.top, 1)
                                    .frame(width: 30, height: 30).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: Space.s2) {
                                    Text(rule.name).font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                                    if rule.needsDesktop { InboxTag(text: "Desktop", color: p.accentWarning) }
                                }
                                Text(rule.conditionSummary).font(AppFont.xs).foregroundStyle(p.textTertiary).lineLimit(2)
                                Text("→ \(rule.actionSummary)").font(AppFont.xs2).foregroundStyle(p.accentViolet)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Space.s5).padding(.vertical, Space.s3)
                        .contentShape(Rectangle())
                        .contextMenu {
                            if !rule.needsDesktop {
                                Button { editingRule = rule } label: { Label("Edit", systemImage: "pencil") }
                            }
                            Button { toggle(rule) } label: {
                                Label(rule.enabled ? "Disable" : "Enable",
                                      systemImage: rule.enabled ? "pause.circle" : "play.circle")
                            }
                            Button(role: .destructive) { pendingDelete = rule } label: {
                                Label("Delete rule", systemImage: "trash")
                            }
                        }
                        if i < rules.count - 1 { SettingsDivider() }
                    }
                }
                .settingsGroup()
            }
            Text("Archive, mark read and triage run on this phone. Create agent rules in the desktop app.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary).padding(.horizontal, Space.s5).padding(.top, Space.s5)
        }
        .task(id: engine.dataVersion) {
            let result = await engine.localRules()
            guard !Task.isCancelled else { return }
            rules = result
        }
        .sheet(isPresented: $showNewRule) { NewRuleSheet() }
        .sheet(item: $editingRule) { NewRuleSheet(editing: $0) }
        .confirmationDialog("Delete this rule?", isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Delete rule", role: .destructive) {
                if let r = pendingDelete { Task { _ = await engine.deleteRule(ruleKey: r.key) } }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("\(pendingDelete?.name ?? "This rule") will stop running on this device.")
        }
    }

    /// Drives the delete confirmation off `pendingDelete` (a Bool the dialog needs).
    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func toggle(_ rule: LocalRule) {
        Task { _ = await engine.setRuleEnabled(ruleKey: rule.key, enabled: !rule.enabled) }
    }
}
