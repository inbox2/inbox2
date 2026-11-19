import SwiftUI

/// A circular, borderless icon action button — the app's most-repeated UI atom
/// (header search / bell, sync, "+", and other toolbar glyphs). It collapses the
/// recurring `Button { } label: { Image(systemName:).font().foregroundStyle()
/// .frame().contentShape(Circle()) }.buttonStyle(.plain)` boilerplate into one
/// place so the tap target (default 38×38) and glyph treatment stay consistent.
///
/// The glyph tint is any `ShapeStyle`, so callers pass a palette color
/// (`p.textSecondary`) or a gradient (the brand ring) without ceremony. `rotation`
/// drives the sync spinner. For pressed/animated variants that need a bespoke
/// `ButtonStyle` (the bulk bar, the floating nav), use those styles directly — this
/// is the plain `.buttonStyle(.plain)` family only.
struct IconButton<Tint: ShapeStyle>: View {
    private let systemName: String
    private let size: CGFloat
    private let glyph: Font
    private let tint: Tint
    private let rotation: Double
    private let action: () -> Void

    init(_ systemName: String,
         size: CGFloat = 38,
         glyph: Font = AppFont.lg,
         tint: Tint,
         rotation: Double = 0,
         action: @escaping () -> Void) {
        self.systemName = systemName
        self.size = size
        self.glyph = glyph
        self.tint = tint
        self.rotation = rotation
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(glyph)
                .foregroundStyle(tint)
                .rotationEffect(.degrees(rotation))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
