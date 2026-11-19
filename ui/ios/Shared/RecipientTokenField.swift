import SwiftUI
import UIKit

/// A tokenized recipient field: committed addresses render as removable chips, and an
/// inline field captures the next address with contact autocomplete beneath. It writes
/// back to a comma-separated `Binding<String>` (chips + the in-progress token), so it's a
/// drop-in for both composers' existing send paths. Shared between the app and the share
/// extension — styling is passed in (`palette`) since the extension has no `\.theme`.
struct RecipientTokenField: View {
    let label: String
    @Binding var text: String
    let contacts: [ShareBridge.Contact]
    var palette: ThemePalette = .dark

    @State private var chips: [String] = []
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var p: ThemePalette { palette }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Space.s2) {
                Text(label).font(AppFont.sm).foregroundStyle(p.textTertiary)
                    .frame(width: 64, alignment: .leading)
                    .padding(.top, Space.s1 + 2)
                TokenFlow(spacing: Space.s1) {
                    ForEach(chips, id: \.self) { chip in chipView(chip) }
                    TextField("", text: fieldText)
                        .font(AppFont.sm).foregroundStyle(p.textPrimary)
                        .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                        .keyboardType(.emailAddress)
                        .focused($focused)
                        .frame(minWidth: 120, minHeight: 26)
                        .onSubmit { commitDraft() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, Space.s2)
            .composeRow(p)

            if focused {
                let matches = suggestions()
                if !matches.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(matches, id: \.email) { c in
                            Button { pick(c) } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(c.name.isEmpty ? c.email : c.name)
                                        .font(AppFont.sm).foregroundStyle(p.textPrimary)
                                    if !c.name.isEmpty {
                                        Text(c.email).font(AppFont.xs3).foregroundStyle(p.textTertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if c.email != matches.last?.email { Divider().overlay(p.borderSubtle) }
                        }
                    }
                    .background(p.bgElevated)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    .padding(.top, Space.s1)
                }
            }
        }
        .onAppear { seedFromText() }
    }

    private func chipView(_ chip: String) -> some View {
        Menu {
            Section(addressOf(chip)) {
                Button { UIPasteboard.general.string = addressOf(chip) } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) { remove(chip) } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        } label: {
            let ink = p.solidChipInk
            let chipView = HStack(spacing: Space.s1) {
                Text(chipDisplay(chip)).font(AppFont.xs).foregroundStyle(ink ?? p.textPrimary).lineLimit(1)
                Image(systemName: "chevron.down").font(AppFont.glyph(9, .semibold)).foregroundStyle(ink ?? p.textTertiary)
            }
            .padding(.leading, Space.s2).padding(.trailing, Space.s1 + 2).padding(.vertical, Space.s1)
            if ink != nil {
                // Groovebox: a solid lavender chip, dark ink, hard 2pt bottom edge (as InboxTag).
                let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                chipView
                    .background(shape.fill(p.accentViolet))
                    .background(shape.fill(Color.scrim(0.55)).offset(y: 2))
            } else {
                chipView
                    .background(p.bgRaised)
                    .overlay(RoundedRectangle(cornerRadius: Radius.full, style: .continuous).stroke(p.borderDefault, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.full, style: .continuous))
            }
        }
        .buttonStyle(.plain)
    }

    /// Friendly label for a chip: the contact's name (matched by address), else any name
    /// parsed from a "Name <email>" token, else the bare address.
    private func chipDisplay(_ chip: String) -> String {
        let addr = addressOf(chip).lowercased()
        if let c = contacts.first(where: { $0.email.lowercased() == addr }), !c.name.isEmpty {
            return c.name
        }
        return displayName(chip)
    }

    // MARK: Token model (chips + draft ⇄ comma-separated `text`)

    private func seedFromText() {
        chips = Self.splitList(text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        draft = ""
        writeBack()
    }

    private func writeBack() {
        let d = draft.trimmingCharacters(in: .whitespaces)
        text = (chips + (d.isEmpty ? [] : [d])).joined(separator: ", ")
    }

    /// The field always carries a leading zero-width space so a backspace on an otherwise
    /// empty field still produces an empty string in the setter — our signal to delete the
    /// last chip (SwiftUI's `TextField` exposes no backspace event). Typing a comma (or
    /// pasting) commits the completed token(s).
    private static let zwsp = "\u{200B}"
    private var fieldText: Binding<String> {
        Binding(
            get: { Self.zwsp + draft },
            set: { newValue in
                guard !newValue.isEmpty else {
                    if !chips.isEmpty { chips.removeLast() }   // backspace past the sentinel
                    draft = ""
                    writeBack()
                    return
                }
                var v = newValue
                if v.hasPrefix(Self.zwsp) { v.removeFirst() }
                let parts = Self.splitList(v)
                if parts.count > 1 {
                    for token in parts.dropLast() {
                        let t = token.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty, !chips.contains(t) { chips.append(t) }
                    }
                    v = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
                }
                draft = v
                writeBack()
            }
        )
    }

    private func commitDraft() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !chips.contains(t) { chips.append(t) }
        draft = ""
        writeBack()
    }

    private func pick(_ c: ShareBridge.Contact) {
        if !chips.contains(c.email) { chips.append(c.email) }
        draft = ""
        writeBack()
    }

    private func remove(_ chip: String) {
        chips.removeAll { $0 == chip }
        writeBack()
    }

    // MARK: Autocomplete

    private func suggestions() -> [ShareBridge.Contact] {
        let token = draft.trimmingCharacters(in: .whitespaces).lowercased()
        guard token.count >= 2 else { return [] }
        let already = Set(chips.map { addressOf($0).lowercased() })
        return Array(contacts.lazy.filter { c in
            (c.email.lowercased().contains(token) || c.name.lowercased().contains(token)) && !already.contains(c.email.lowercased())
        }.prefix(5))
    }

    // MARK: Display helpers (no MailAddress dependency — keep extension-safe)

    /// Split an address list on commas outside quotes/angle brackets, so
    /// `"Veger, Nick" <v@x>` stays one recipient. Keeps a trailing empty part
    /// (the draft after a just-typed comma).
    static func splitList(_ s: String) -> [String] {
        var parts: [String] = [], cur = ""
        var inQuote = false, inAngle = false, escaped = false
        for ch in s {
            if escaped { escaped = false; cur.append(ch); continue }
            switch ch {
            case "\\" where inQuote: escaped = true
            case "\"": inQuote.toggle()
            case "<": inAngle = true
            case ">": inAngle = false
            case "," where !inQuote && !inAngle: parts.append(cur); cur = ""; continue
            default: break
            }
            cur.append(ch)
        }
        parts.append(cur)
        return parts
    }

    /// A chip may be "Name <email>" or a bare address; show the friendly part.
    private func displayName(_ s: String) -> String {
        if let lt = s.firstIndex(of: "<") {
            var name = s[..<lt].trimmingCharacters(in: .whitespaces)
            if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
                name = String(name.dropFirst().dropLast())
                    .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            }
            if !name.isEmpty { return name }
        }
        return addressOf(s)
    }

    private func addressOf(_ s: String) -> String {
        guard let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), lt < gt else {
            return s.trimmingCharacters(in: .whitespaces)
        }
        return String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
    }
}

/// Minimal wrapping layout for the chips + inline field (the app's `FlowRow` lives in the
/// app-only Primitives.swift, so the shared field carries its own).
private struct TokenFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension View {
    /// A composer field row: a bottom hairline, or — where the theme draws solid
    /// panels (Groovebox) — a rounded `bgRaised` well. Shared by both composers.
    @ViewBuilder func composeRow(_ p: ThemePalette) -> some View {
        if p.panelRadius != nil {
            padding(.horizontal, Space.s3)
                .background(p.bgRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            overlay(alignment: .bottom) { Rectangle().fill(p.borderSubtle).frame(height: 1) }
        }
    }
}
