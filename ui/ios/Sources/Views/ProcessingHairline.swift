import SwiftUI

/// A 1pt animated gradient hairline — the ambient "AI is working" indicator.
/// Indeterminate: a brand-gradient band sweeps along a faint base line. Used at
/// the bottom of the inbox list (the triage worker is processing) and under the
/// reader header (THIS thread's summaries are being [re]generated). Purely
/// decorative — never intercepts touches.
struct ProcessingHairline: View {
    @Environment(\.theme) private var theme
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            let band = max(80, geo.size.width * 0.35)
            LinearGradient(
                colors: [.clear] + theme.palette.ringColors + [.clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: band)
            .offset(x: sweep ? geo.size.width : -band)
        }
        .frame(height: 1)
        .background(theme.palette.accentViolet.opacity(0.18))
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}
