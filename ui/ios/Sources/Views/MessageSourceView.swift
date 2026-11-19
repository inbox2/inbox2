import SwiftUI

/// "View source" popup — all original message details (headers + raw body), like
/// the desktop's view-source. Presented as a sheet from the message details bar.
struct MessageSourceView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let message: Message
    private var p: ThemePalette { theme.palette }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    section("Headers") {
                        LabeledRow("From", message.fromAddress, labelWidth: 72)
                        LabeledRow("To", message.toAddress, labelWidth: 72)
                        if let cc = message.ccAddress, !cc.isEmpty { LabeledRow("Cc", cc, labelWidth: 72) }
                        LabeledRow("Subject", message.subject, labelWidth: 72)
                        LabeledRow("Date", message.createdAt, labelWidth: 72)
                        LabeledRow("Message ID", message.id, labelWidth: 72)
                    }
                    section(message.bodyHTML != nil ? "Body (HTML)" : "Body") {
                        Text(message.bodyHTML ?? message.bodyPlain ?? "(no content)")
                            .font(AppFont.mono(12))
                            .foregroundStyle(p.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Space.s4)
            }
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle("Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(p.accentViolet)
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title.uppercased()).font(AppFont.xs3(.semibold)).tracking(0.8)
                .foregroundStyle(p.textTertiary)
            content()
        }
    }

}

/// A label/value row — the Details disclosure (38-pt labels) and the raw source
/// sheet (wider 72-pt labels like "Message ID") share this.
struct LabeledRow: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    var labelWidth: CGFloat = 38
    init(_ label: String, _ value: String, labelWidth: CGFloat = 38) {
        self.label = label; self.value = value; self.labelWidth = labelWidth
    }
    var body: some View {
        HStack(alignment: .top, spacing: Space.s2) {
            Text(label).font(AppFont.xs3).foregroundStyle(theme.palette.textTertiary).frame(width: labelWidth, alignment: .leading)
            Text(value).font(AppFont.xs2).foregroundStyle(theme.palette.textSecondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
