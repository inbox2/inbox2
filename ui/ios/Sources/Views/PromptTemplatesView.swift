import SwiftUI

/// Dev-mode prompt template editor — the desktop Triage Lab's template editor,
/// reshaped for mobile: instead of one big TOML, the template's sections (Chat,
/// Daily brief, …, Thread summary, OpenAI model) each get their own editor screen, and
/// the core reconstructs + validates the override file from the edited texts
/// (`build_prompt_overrides`). Sections matching the embedded defaults are
/// omitted from the persisted file, so it only ever carries real edits; a broken
/// edit is rejected with an inline message and changes nothing.
struct PromptTemplatesView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @State private var sections: [FfiPromptSection] = []
    @State private var defaults: [String: String] = [:]
    private var p: ThemePalette { theme.palette }

    /// Section metadata keyed by the TOML table name (titles/icons are
    /// presentation; the keys come from the core's section list).
    private static let meta: [String: (title: String, icon: String, blurb: String)] = [
        "chat": ("Voice chat", "bubble.left.and.bubble.right", "Conversational Bridge replies and commands."),
        "brief": ("Daily brief", "sunrise", "The spoken morning briefing."),
        "tomorrow": ("Tomorrow preview", "calendar.badge.clock", "Tomorrow's spoken calendar preview."),
        "week": ("Week ahead", "calendar", "The conversational week rundown."),
        "draft_reply": ("Draft reply", "square.and.pencil", "Drafts a reply for you to check."),
        "summary": ("Thread summary", "tray.full", "The short and medium summary for every thread. Jev picks labels, priority and Space."),
        "openai": ("OpenAI model", "sparkles", "The chat model name for the OpenAI lane."),
    ]

    var body: some View {
        SettingsScaffold(title: "Prompt templates") {
            SettingsHeader(text: "Sections")
            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.key) { index, section in
                    let meta = Self.meta[section.key] ?? (section.key, "doc.text", "")
                    NavigationLink {
                        PromptSectionEditor(
                            title: meta.title,
                            blurb: meta.blurb,
                            modelName: section.key == "openai",
                            text: section.text,
                            defaultText: defaults[section.key] ?? "",
                            onApply: { newText in apply(newText, at: index) }
                        )
                    } label: {
                        sectionRow(meta.title, icon: meta.icon, edited: isEdited(section))
                    }
                    .buttonStyle(.plain)
                    if section.key != sections.last?.key { SettingsDivider() }
                }
            }
            .settingsGroup()

            Text("Edits apply on this device right away and stay after a restart. Reset a section to go back to the default. Edit triage labels under Triage & sync › Labels.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                .padding(.horizontal, Space.s5).padding(.top, Space.s3).padding(.bottom, Space.s5)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        sections = engine.promptSections()
        defaults = engine.defaultPromptSections()
    }

    private func isEdited(_ section: FfiPromptSection) -> Bool {
        defaults[section.key].map { $0 != section.text } ?? false
    }

    /// Menu row with an "edited" badge when the section overrides its default.
    private func sectionRow(_ title: String, icon: String, edited: Bool) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: icon).font(AppFont.body).foregroundStyle(p.textSecondary).frame(width: 28)
            Text(title).font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
            if edited {
                InboxTag(text: "edited", color: p.accentViolet)
            }
            Spacer()
            Image(systemName: "chevron.right").font(AppFont.xs(.semibold)).foregroundStyle(p.textMuted)
        }
        .padding(.horizontal, Space.s5).frame(minHeight: 54).contentShape(Rectangle())
    }

    /// Apply one section's edit: rebuild the override from all current texts with
    /// this one swapped in. Returns the core's validation error, nil on success.
    private func apply(_ newText: String, at index: Int) -> String? {
        var updated = sections
        updated[index] = FfiPromptSection(key: updated[index].key, text: newText)
        if let err = engine.applyPromptSections(updated) { return err }
        sections = updated
        return nil
    }
}

/// One section's full-screen editor: the template text in a monospaced editor,
/// Save & apply in the header, and a reset-to-default action. Validation errors
/// from the core (e.g. a triage prompt missing {labels}) surface inline and
/// nothing is installed or persisted until the edit passes.
struct PromptSectionEditor: View {
    @Environment(\.theme) private var theme
    let title: String
    let blurb: String
    /// True for the `[openai]` section — a one-line model name, not a prompt.
    let modelName: Bool
    @State var text: String
    let defaultText: String
    /// Rebuilds + applies the override; returns the validation error or nil.
    let onApply: (String) -> String?

    @State private var savedText: String
    @State private var error: String?
    @State private var confirmation: String?
    @FocusState private var focused: Bool
    private var p: ThemePalette { theme.palette }

    init(title: String, blurb: String, modelName: Bool, text: String,
         defaultText: String, onApply: @escaping (String) -> String?) {
        self.title = title
        self.blurb = blurb
        self.modelName = modelName
        _text = State(initialValue: text)
        self.defaultText = defaultText
        self.onApply = onApply
        _savedText = State(initialValue: text)
    }

    private var dirty: Bool { text != savedText }
    private var isDefault: Bool { text == defaultText }

    var body: some View {
        SettingsScaffold(title: title, trailing: {
            Button { save() } label: {
                Text("Save")
                    .font(AppFont.base(.semibold))
                    .foregroundStyle(dirty ? p.accentViolet : p.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!dirty)
        }) {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(blurb).font(AppFont.xs2).foregroundStyle(p.textTertiary)

                if modelName {
                    TextField("gpt-4o-mini", text: $text)
                        .font(AppFont.mono(14))
                        .foregroundStyle(p.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(Space.s3)
                        .background(p.bgElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(p.borderSubtle, lineWidth: 1))
                        .focused($focused)
                } else {
                    TextEditor(text: $text)
                        .font(AppFont.mono(13))
                        .foregroundStyle(p.textPrimary)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 380)
                        .padding(Space.s2)
                        .background(p.bgElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(p.borderSubtle, lineWidth: 1))
                        .focused($focused)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(AppFont.xs2).foregroundStyle(p.accentDanger)
                }
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle")
                        .font(AppFont.xs2).foregroundStyle(p.accentSuccess)
                }

                if !isDefault {
                    Button {
                        text = defaultText
                        save()
                    } label: {
                        Label("Reset to default", systemImage: "arrow.uturn.backward")
                            .font(AppFont.sm(.medium)).foregroundStyle(p.accentAmber)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Space.s1)
                }
            }
            .padding(.horizontal, Space.s5).padding(.top, Space.s2)
        }
    }

    private func save() {
        focused = false
        confirmation = nil
        if let err = onApply(text) {
            error = err
            return
        }
        error = nil
        savedText = text
        confirmation = isDefault ? "Back to the default." : "Saved on this device."
    }
}
