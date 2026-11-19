import SwiftUI

// First wave of ported design-system primitives. Each reads the active Theme from
// the environment so it tracks the light/dark switch automatically.

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Pill badge with a dim accent fill, e.g. status / labels.
struct InboxTag: View {
    @Environment(\.theme) private var theme
    let text: String
    var color: Color?

    var body: some View {
        let c = color ?? theme.palette.accentPrimary
        let label = Text(text)
            .font(AppFont.xs3)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, 3)
        if let ink = theme.palette.solidChipInk {
            // Groovebox: a solid pastel chip with dark ink and a hard 2pt bottom edge.
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            label
                .foregroundStyle(ink)
                .background(shape.fill(c))
                .background(shape.fill(Color.scrim(0.55)).offset(y: 2))
        } else {
            label
                .foregroundStyle(c)
                .background(c.opacity(0.13))
                .clipShape(Capsule())
        }
    }
}

/// Panel surface with groove border — the base for cards/rows.
struct InboxCard<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.bgRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .stroke(theme.palette.borderDefault, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
            .shadow(color: .black.opacity(theme.palette.isDark ? 0.22 : 0.08), radius: 8, y: 2)
    }
}

/// Small uppercase group label sitting above a form/section card. The leading
/// pad lines it up with the card's inner content.
struct SectionLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(AppFont.xs3)
            .tracking(0.6)
            .foregroundStyle(theme.palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Space.s3)
    }
}

/// One field/row inside a form card — consistent height + horizontal padding so
/// stacked rows share the inbox card's row rhythm. Put a `SettingsDivider`
/// between rows and wrap the stack in `.insetCard()`.
struct FormRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.s4)
            .frame(minHeight: 50)
    }
}

/// Recessed input field.
struct InboxTextField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(AppFont.sm)
            .foregroundStyle(theme.palette.textPrimary)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2 + 1)
            .background(theme.palette.bgInput)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(theme.palette.borderDefault, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

/// Minimal wrapping HStack for tags/pills — items flow left-to-right and wrap to the
/// next line when they run out of width. Uses the iOS 16+ Layout API (SwiftUI has no
/// native flow layout). Used by the style guide and the message tag bar.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A recessed API-key input row with an inline trailing action. Empty → an editable
/// `SecureField` + "Save"; saved → a key glyph, the masked value, and "Reset". Used
/// for both the inbox2 image-proxy key and the OpenAI key so they stay identical.
///
/// Save IS the validation: `onSave` validates + persists the typed value and returns
/// nil on success, or an error message to reject it (keeps editing, shows the
/// message). It may be async (e.g. a network key test) — the row shows a spinner
/// while it runs. The component owns the in-progress draft; the caller owns storage.
/// Edge-to-edge — the caller adds any screen-margin padding.
struct ApiKeyField: View {
    @Environment(\.theme) private var theme
    /// The currently-stored key (shown masked), or nil when none is saved.
    let savedValue: String?
    var placeholder: String = "ink_…"
    /// Validate + persist the typed value. nil = success; non-nil = error to show.
    let onSave: (String) async -> String?
    let onReset: () -> Void

    @State private var draft = ""
    @State private var saving = false
    @State private var errorText: String?
    private var p: ThemePalette { theme.palette }

    private var canSave: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && !saving }
    /// First 8 chars + ellipsis — recognisable without revealing the key.
    private func masked(_ v: String) -> String { String(v.prefix(8)) + "…" }

    private func save() {
        guard canSave else { return }
        saving = true; errorText = nil
        Task { @MainActor in
            let err = await onSave(draft)
            saving = false
            if let err { errorText = err } else { draft = "" }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                if let saved = savedValue {
                    Image(systemName: "key.fill").font(AppFont.sm).foregroundStyle(p.accentSuccess)
                    Text(masked(saved)).font(AppFont.mono(13)).foregroundStyle(p.textSecondary)
                    Spacer(minLength: Space.s2)
                    Button("Reset") { onReset(); draft = ""; errorText = nil }
                        .font(AppFont.sm(.semibold)).foregroundStyle(p.accentDanger)
                        .buttonStyle(.plain)
                } else {
                    SecureField(placeholder, text: $draft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(AppFont.sm).foregroundStyle(p.textPrimary)
                        .onSubmit(save)
                        .disabled(saving)
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save", action: save)
                            .font(AppFont.sm(.semibold))
                            .foregroundStyle(canSave ? p.accentViolet : p.textMuted)
                            .buttonStyle(.plain).disabled(!canSave)
                    }
                }
            }
            .padding(.horizontal, Space.s4).frame(minHeight: 50)
            .background(p.bgInput)
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(p.borderDefault, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

            if let errorText {
                Text(errorText).font(AppFont.xs).foregroundStyle(p.accentDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
