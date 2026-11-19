import SwiftUI

/// The Groovebox guidebook scene, ported from ui/web/src/lib/groovebox.js: a
/// charcoal ground under a violet isometric line grid, plus (optionally) outlined
/// pastel objects parked around the edges — rainbow arcs, a dial, pyramids,
/// keycaps, felt pom-poms. `progress` in [0, 1] plays the web's draw-in: the grid
/// fades up over the first 40%, then the objects appear one after another.
///
/// The inbox backdrop draws it static and grid-only (the list well covers the
/// edges the objects would sit on); the launch splash animates the full scene.
struct GrooveboxScene: View {
    var shapes = true
    var progress: Double = 1
    /// Grid line alpha: 0.22 behind app content (phone backdrops), the web's 0.42
    /// on the launch splash where nothing sits on top.
    var gridAlpha: Double = 0.22

    // Scene colours — the theme's own pastels (lib/groovebox.js), not palette roles.
    static let ground = Color(hex: "2a2a2e")
    private static let grid = Color(r: 148, g: 121, b: 216)
    private static let ink = Color(hex: "f3f0ea")
    private static let coral = Color(hex: "f2785c")
    private static let mustard = Color(hex: "f0b545")
    private static let teal = Color(hex: "44c2b3")
    private static let lavender = Color(hex: "a68cf0")
    private static let pink = Color(hex: "f0a3bd")

    /// Isometric rhombus cell (30° lines): ~64×37pt on a phone.
    private static let cellW: CGFloat = 64
    private static let cellH: CGFloat = cellW * tan(.pi / 6)

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.ground))

            var g = ctx
            g.opacity = min(1, progress / 0.4)
            g.stroke(Self.gridPath(w, h), with: .color(Self.grid.opacity(gridAlpha)), lineWidth: 1.5)

            guard shapes else { return }
            let items = Self.layout(w, h)
            let t = max(0, (progress - 0.3) / 0.7) * Double(items.count)
            for (i, item) in items.enumerated() {
                let a = min(1, max(0, t - Double(i)))
                guard a > 0 else { continue }
                var c = ctx
                c.opacity = a
                item(&c)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static func gridPath(_ w: CGFloat, _ h: CGFloat) -> Path {
        var path = Path()
        // Two families of 30° lines; extend past the edges so the rhombi tile clean.
        let slope = cellH / cellW
        let span = w * slope + h
        var c = -span
        while c <= span + h {
            path.move(to: CGPoint(x: 0, y: c)); path.addLine(to: CGPoint(x: w, y: c + w * slope))
            path.move(to: CGPoint(x: 0, y: c)); path.addLine(to: CGPoint(x: w, y: c - w * slope))
            c += cellH
        }
        return path
    }

    /// The objects, in draw-in order, as closures over a graphics context.
    private static func layout(_ w: CGFloat, _ h: CGFloat) -> [(inout GraphicsContext) -> Void] {
        let u = max(0.6, min(w, h) / 900)
        let lw = 3 * u
        let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        var items: [(inout GraphicsContext) -> Void] = []

        // Bottom-left: rainbow arcs, outermost first.
        for (i, color) in [coral, mustard, teal, lavender].enumerated() {
            let r = (300 - CGFloat(i) * 34) * u
            items.append { c in
                var p = Path()
                p.addArc(center: CGPoint(x: -20 * u, y: h + 20 * u), radius: r,
                         startAngle: .radians(-.pi / 2), endAngle: .zero, clockwise: false)
                c.stroke(p, with: .color(color), style: stroke)
            }
        }
        // Top-left: a big dial with its crescent.
        items.append { c in
            let x = 120 * u, y = 110 * u, r = 70 * u
            var p = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            p.addArc(center: CGPoint(x: x + r * 0.12, y: y - r * 0.2), radius: r * 0.36,
                     startAngle: .radians(.pi * 0.75), endAngle: .radians(.pi * 2.1), clockwise: false)
            c.stroke(p, with: .color(lavender), style: stroke)
        }
        // Top-right: two pyramids.
        for (x, y, s, color) in [(w - 150 * u, 150 * u, 120 * u, coral), (w - 60 * u, 200 * u, 90 * u, mustard)] {
            items.append { c in
                var p = Path()
                p.move(to: CGPoint(x: x - s * 0.6, y: y))
                p.addLine(to: CGPoint(x: x, y: y - s))
                p.addLine(to: CGPoint(x: x + s * 0.6, y: y))
                p.closeSubpath()
                p.move(to: CGPoint(x: x, y: y - s))
                p.addLine(to: CGPoint(x: x + s * 0.12, y: y))
                c.stroke(p, with: .color(color), style: stroke)
            }
        }
        // Right edge: stacked keycaps; bottom-right: one cream key.
        let k = 92 * u
        for (x, y, color) in [(w - 140 * u, h * 0.52, teal), (w - 110 * u, h * 0.52 + 120 * u, mustard),
                              (w - 230 * u, h - 120 * u, ink)] {
            items.append { c in
                func cap(_ x: CGFloat, _ y: CGFloat, _ cw: CGFloat, _ ch: CGFloat, _ r: CGFloat) -> Path {
                    Path(roundedRect: CGRect(x: x, y: y, width: cw, height: ch), cornerRadius: r)
                }
                // Ghost (the keycap's skirt), then the cap and its legend slot.
                var ghost = c
                ghost.opacity *= 0.5
                ghost.stroke(cap(x + 8 * u, y - 8 * u, k, k * 0.82, 20 * u), with: .color(color), style: stroke)
                c.stroke(cap(x, y, k, k * 0.82, 20 * u), with: .color(color), style: stroke)
                c.stroke(cap(x + k * 0.3, y + k * 0.16, k * 0.38, k * 0.2, k * 0.1), with: .color(ink), style: stroke)
            }
        }
        // Felt pom-poms along the bottom and top edges.
        let poms: [(CGFloat, CGFloat, Color)] = [
            (0.32, 0.96, coral), (0.55, 0.985, lavender), (0.74, 0.93, teal),
            (0.42, 0.04, pink), (0.63, 0.025, mustard), (0.88, 0.97, pink),
        ]
        for (fx, fy, color) in poms {
            items.append { c in
                let r = 9 * u
                c.fill(Path(ellipseIn: CGRect(x: w * fx - r, y: h * fy - r, width: 2 * r, height: 2 * r)),
                       with: .color(color))
            }
        }
        return items
    }
}

/// The Groovebox launch animation: the full scene drawing itself in over `duration`,
/// then holding on the last frame.
struct GrooveboxLaunchScene: View {
    var duration: Double = 1.6
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { tl in
            GrooveboxScene(progress: min(1, tl.date.timeIntervalSince(start) / duration), gridAlpha: 0.42)
        }
    }
}
