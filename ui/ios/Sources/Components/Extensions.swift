import SwiftUI

/// Loose bundle PNGs (copied via the Resources build phase) aren't found by
/// `UIImage(named:)` — load them by bundle path, like the email-body bundle.
/// Cached so repeated renders (avatars, the channel switcher, logo tiles) don't
/// re-read + re-decode from disk. Accessed from SwiftUI bodies on the main actor.
enum BundledImage {
    private static let cache = NSCache<NSString, UIImage>()
    static func named(_ name: String) -> UIImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let img = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: name as NSString)
        return img
    }
}

extension UIImage {
    private static let gradientSymbolCache = NSCache<NSString, UIImage>()

    /// An SF Symbol filled with a top-leading→bottom-trailing linear gradient,
    /// returned as `.alwaysOriginal` so contexts that flatten template images to a
    /// solid tint — notably SwiftUI swipe-action labels — keep the gradient. Cached.
    static func gradientSymbol(_ name: String, colors: [UIColor],
                               pointSize: CGFloat = 20, weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
        let key = "\(name)|\(pointSize)|\(weight.rawValue)|\(colors.map(\.hashValue).reduce(0, ^))" as NSString
        if let hit = gradientSymbolCache.object(forKey: key) { return hit }
        let cfg = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = UIImage(systemName: name, withConfiguration: cfg) else { return nil }
        let size = symbol.size
        let out = UIGraphicsImageRenderer(size: size).image { ctx in
            symbol.withRenderingMode(.alwaysTemplate).draw(in: CGRect(origin: .zero, size: size))
            ctx.cgContext.setBlendMode(.sourceIn)   // fill only the glyph's alpha
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors.map(\.cgColor) as CFArray, locations: nil) {
                ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }.withRenderingMode(.alwaysOriginal)
        gradientSymbolCache.setObject(out, forKey: key)
        return out
    }
}

extension AttributedString {
    /// The product label `inbox2 mx` with `mx` set in a monospaced (code) face.
    /// Other runs carry no explicit font, so they inherit the host `Text`'s font —
    /// callers keep their existing sizing/smallCaps and only `mx` turns monospace.
    static func inbox2mx(monoSize: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var s = AttributedString("inbox2 ")
        var mx = AttributedString("mx")
        mx.font = AppFont.mono(monoSize, weight)
        s.append(mx)
        return s
    }
}
