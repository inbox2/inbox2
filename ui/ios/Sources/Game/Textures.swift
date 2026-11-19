import UIKit

// Procedurally generated synthwave textures so the game looks complete before any
// Higgsfield art is wired in. Higgsfield-generated PNGs (Resources/sx-*.png) can later
// replace these by name without touching gameplay.

enum TextureGen {
    /// A seamless neon grid tile (dark base + glowing lines) for the scrolling floor.
    static func grid(line: UIColor, base: UIColor = .black, size: CGFloat = 256, step: CGFloat = 32) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { ctx in
            let c = ctx.cgContext
            c.setFillColor(base.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            c.setStrokeColor(line.cgColor)
            c.setLineWidth(2)
            var x: CGFloat = 0
            while x <= size {
                c.move(to: CGPoint(x: x, y: 0)); c.addLine(to: CGPoint(x: x, y: size))
                c.move(to: CGPoint(x: 0, y: x)); c.addLine(to: CGPoint(x: size, y: x))
                x += step
            }
            c.strokePath()
        }
    }

    /// A vertical synthwave gradient backdrop with a soft sun glow — used as the far
    /// scene background per biome.
    static func nebula(top: UIColor, bottom: UIColor, glow: UIColor, size: CGFloat = 512) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray,
                                  locations: [0, 1]) {
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size), options: [])
            }
            // Soft sun glow low-centre.
            let center = CGPoint(x: size / 2, y: size * 0.72)
            if let g = CGGradient(colorsSpace: space,
                                  colors: [glow.withAlphaComponent(0.85).cgColor,
                                           glow.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                c.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                     endCenter: center, endRadius: size * 0.45, options: [])
            }
        }
    }

    /// A small round soft sprite for star / spark particles.
    static func dot(_ color: UIColor, size: CGFloat = 32) -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return r.image { ctx in
            let c = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let center = CGPoint(x: size / 2, y: size / 2)
            if let g = CGGradient(colorsSpace: space,
                                  colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                c.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                     endCenter: center, endRadius: size / 2, options: [])
            }
        }
    }
}
