import SwiftUI

/// Settings › Triage & sync › Labels — the local-channel label list Jev chooses from
/// (engine setting `triage_labels`, docs/Triage.md). Built-ins can be switched off
/// (except `fyi`, the fallback) and their description / "not for" edited; custom
/// labels can be added, edited and deleted. The core validates every save.
struct TriageLabelsView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @State private var labels: [TriageLabelDef] = []
    @State private var editing: TriageLabelDef?
    @State private var adding = false
    @State private var error: String?
    private var p: ThemePalette { theme.palette }

    var body: some View {
        SettingsScaffold(title: "Labels", trailing: {
            SettingsAddButton { adding = true }
        }) {
            SettingsHeader(text: "\(labels.filter(\.enabled).count) of \(labels.count) enabled")
            VStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.element.id) { i, label in
                    row(label)
                    if i < labels.count - 1 { SettingsDivider() }
                }
            }
            .settingsGroup()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(AppFont.xs2).foregroundStyle(p.accentDanger)
                    .padding(.horizontal, Space.s5).padding(.top, Space.s3)
            }
            Text("Jev gives every thread in your accounts one of the enabled labels. The description says what a label is for. \u{201C}Not for\u{201D} lists look-alikes to skip. FYI catches the rest and stays on.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                .padding(.horizontal, Space.s5).padding(.top, Space.s5)
        }
        .onAppear { labels = engine.triageLabels() }
        .sheet(item: $editing) { label in
            TriageLabelSheet(label: label, isNew: false, onSave: { save(replacing: label.slug, with: $0) },
                             onDelete: label.builtin ? nil : { save(replacing: label.slug, with: nil) })
        }
        .sheet(isPresented: $adding) {
            TriageLabelSheet(label: TriageLabelDef(slug: "", name: "", description: ""), isNew: true,
                             onSave: { save(replacing: nil, with: $0) }, onDelete: nil)
        }
    }

    private func row(_ label: TriageLabelDef) -> some View {
        let locked = label.slug == TriageLabel.fyi.rawValue
        return HStack(alignment: .top, spacing: Space.s3) {
            Button {
                var l = label; l.enabled.toggle()
                error = save(replacing: label.slug, with: l)
            } label: {
                Image(systemName: locked ? "lock.fill" : (label.enabled ? "checkmark.circle.fill" : "circle"))
                    .font(AppFont.body)
                    .foregroundStyle(locked ? p.textMuted : (label.enabled ? p.accentSuccess : p.textMuted))
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked)
            Button { editing = label } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Space.s2) {
                        Text(label.name).font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                        if !label.builtin { InboxTag(text: "Custom", color: p.accentViolet) }
                    }
                    Text(label.description).font(AppFont.xs).foregroundStyle(p.textTertiary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Image(systemName: "chevron.right").font(AppFont.xs(.semibold)).foregroundStyle(p.textMuted).padding(.top, 6)
        }
        .padding(.horizontal, Space.s5).padding(.vertical, Space.s3)
        .opacity(label.enabled ? 1 : 0.6)
    }

    /// Replace (or add, `slug == nil`; or delete, `new == nil`) one label and hand the
    /// whole list to the core. Returns the core's validation error, nil on success.
    @discardableResult
    private func save(replacing slug: String?, with new: TriageLabelDef?) -> String? {
        var next = labels
        if let slug, let i = next.firstIndex(where: { $0.slug == slug }) {
            if let new { next[i] = new } else { next.remove(at: i) }
        } else if let new {
            next.append(new)
        }
        switch engine.setTriageLabels(next) {
        case .success(let stored): labels = stored; return nil
        case .failure(.Engine(let msg)): return msg
        }
    }
}

/// Add / edit one label. Built-ins: only description + "not for" are editable.
/// Custom: name, description, "not for"; the slug is derived from the name on
/// create and fixed after (stored threads reference it).
private struct TriageLabelSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State var label: TriageLabelDef
    let isNew: Bool
    /// Returns the core's validation error, nil on success.
    let onSave: (TriageLabelDef) -> String?
    let onDelete: (() -> String?)?
    @State private var error: String?
    @State private var confirmDelete = false
    private var p: ThemePalette { theme.palette }

    private var canSave: Bool {
        !label.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !label.description.trimmingCharacters(in: .whitespaces).isEmpty
            && (!isNew || TriageLabelDef.isValidCustomSlug(label.slug))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if label.builtin {
                        Text(label.name).foregroundStyle(p.textSecondary)
                    } else {
                        TextField("Name", text: $label.name)
                            .onChange(of: label.name) { _, name in if isNew { label.slug = Self.slug(from: name) } }
                    }
                } header: { Text("Name") } footer: {
                    if isNew && !label.slug.isEmpty {
                        Text(TriageLabelDef.isValidCustomSlug(label.slug)
                             ? "Stored as \u{201C}\(label.slug)\u{201D}."
                             : "\u{201C}\(label.slug)\u{201D} is a built-in label. Pick another name.")
                    }
                }
                Section {
                    TextField("What mail gets this label", text: $label.description, axis: .vertical)
                        .lineLimit(2...6)
                } header: { Text("Description") }
                Section {
                    TextField("Optional: look-alikes to skip", text: $label.notFor, axis: .vertical)
                        .lineLimit(1...4)
                } header: { Text("Not for") }
                if let onDelete {
                    Section {
                        Button("Delete label", role: .destructive) { confirmDelete = true }
                    }
                    .confirmationDialog("Delete \u{201C}\(label.name)\u{201D}?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Delete label", role: .destructive) {
                            if let err = onDelete() { error = err } else { dismiss() }
                        }
                    } message: {
                        Text("Threads already labelled keep it until they're triaged again.")
                    }
                }
                if let error {
                    Section { Text(error).font(AppFont.sm).foregroundStyle(p.accentDanger) }
                }
            }
            .scrollContentBackground(.hidden)
            .pageBackground()
            .navigationTitle(isNew ? "New label" : label.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(p.accentViolet)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        if let err = onSave(label) { error = err } else { dismiss() }
                    }
                    .disabled(!canSave)
                    .foregroundStyle(canSave ? p.accentViolet : p.textTertiary)
                }
            }
        }
    }

    /// "Legal review!" → "legal_review" (`[a-z0-9_]{1,40}`).
    static func slug(from name: String) -> String {
        let mapped = name.lowercased().map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber)) ? c : "_"
        }
        let collapsed = String(mapped).split(separator: "_").joined(separator: "_")
        return String(collapsed.prefix(40))
    }
}
