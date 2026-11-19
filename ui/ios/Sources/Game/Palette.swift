import SceneKit
import UIKit

// Shared neon-synthwave palette + SceneKit material helpers for the space shooter.
// Flat (`.lambert`) shading with emissive neon accents reads synthwave under a dark,
// low-ambient lighting rig — the bulk of the "yesterday's pixels" look comes from the
// constrained palette + low-res nearest upscale (see SpaceShooterGameView).

enum Synth {
    static let magenta = UIColor(red: 1.00, green: 0.22, blue: 0.71, alpha: 1)
    static let pink    = UIColor(red: 1.00, green: 0.36, blue: 0.66, alpha: 1)
    static let cyan    = UIColor(red: 0.31, green: 0.94, blue: 1.00, alpha: 1)
    static let aqua    = UIColor(red: 0.55, green: 0.93, blue: 1.00, alpha: 1)
    static let purple  = UIColor(red: 0.55, green: 0.30, blue: 0.95, alpha: 1)
    static let violet  = UIColor(red: 0.63, green: 0.36, blue: 1.00, alpha: 1)
    static let amber   = UIColor(red: 1.00, green: 0.62, blue: 0.30, alpha: 1)
    static let red     = UIColor(red: 1.00, green: 0.28, blue: 0.36, alpha: 1)
    static let lime    = UIColor(red: 0.65, green: 1.00, blue: 0.42, alpha: 1)
    static let white   = UIColor(red: 0.95, green: 0.97, blue: 1.00, alpha: 1)

    static let hullDark  = UIColor(red: 0.09, green: 0.07, blue: 0.16, alpha: 1)
    static let hullSteel = UIColor(red: 0.16, green: 0.16, blue: 0.26, alpha: 1)
    static let indigo    = UIColor(red: 0.035, green: 0.027, blue: 0.090, alpha: 1)  // bg / fog
    static let silver    = UIColor(red: 0.74, green: 0.77, blue: 0.84, alpha: 1)     // player hull
    static let gunmetal  = UIColor(red: 0.20, green: 0.22, blue: 0.28, alpha: 1)     // creases / weapons
    static let teal      = UIColor(red: 0.00, green: 0.92, blue: 0.82, alpha: 1)     // player accent / ring
    static let neonGreen = UIColor(red: 0.20, green: 1.00, blue: 0.38, alpha: 1)     // player health pips
    static let orange    = UIColor(red: 1.00, green: 0.50, blue: 0.12, alpha: 1)     // thrust / fire

    /// A brushed-metal player-hull material: phong silver with white speculars so the
    /// magenta/cyan lights carve creases and shadows into it (reads metallic, not flat).
    static func metal(_ base: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = base
        m.specular.contents = UIColor.white
        m.shininess = 0.85
        m.locksAmbientWithDiffuse = true
        return m
    }

    /// A flat-shaded material with an optional neon emissive accent.
    static func mat(_ diffuse: UIColor, emission: UIColor? = nil, glow: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = diffuse
        if let e = emission {
            m.emission.contents = e
            m.emission.intensity = glow
        }
        m.locksAmbientWithDiffuse = true
        return m
    }

    /// A fully self-lit neon material (cores, projectiles, grid).
    static func neon(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.emission.contents = color
        m.emission.intensity = 1
        return m
    }
}
