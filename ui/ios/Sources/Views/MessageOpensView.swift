import SwiftUI

// The open-history sheet: each recorded open with time, location, device, and a
// proxy/prefetch flag (docs/Open-Tracking.md).
struct MessageOpensView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let opens: [MessageOpen]
    private var p: ThemePalette { theme.palette }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    if opens.isEmpty {
                        Text("No opens recorded yet.").font(AppFont.sm).foregroundStyle(p.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.top, Space.s6)
                    }
                    ForEach(opens) { o in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(o.openedAt).font(AppFont.sm(.semibold)).foregroundStyle(p.textPrimary)
                                Spacer()
                                if o.proxied {
                                    InboxTag(text: o.proxyKind ?? "proxy", color: p.accentAmber)
                                }
                            }
                            Text(o.location).font(AppFont.xs).foregroundStyle(p.textSecondary)
                            if let ua = o.userAgent, !ua.isEmpty {
                                Text(ua).font(AppFont.mono(11)).foregroundStyle(p.textTertiary).lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s3)
                        .background(RoundedRectangle(cornerRadius: Radius.md).fill(p.bgSurface))
                    }
                }
                .padding(Space.s4)
            }
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle("Opens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(p.accentViolet)
                }
            }
        }
    }
}
