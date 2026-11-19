import SceneKit
import UIKit

// Procedural low-poly ship kit. Ships are composed from primitives (box / cone /
// cylinder) into a parent node oriented **nose toward −Z** (forward), then
// `flattenedClone()`d into a single node for cheap drawing. A small parameter set
// (`Params`) yields many distinct hulls; bosses are assembled separately (their parts
// stay individual nodes so weak points can be destroyed) — see ShipSpecs.

enum ShipKit {
    enum Wing { case delta, swept, forward, none }

    struct Params {
        var length: Float = 2.2
        var width: Float = 2.0
        var body: UIColor = Synth.hullDark
        var accent: UIColor = Synth.cyan
        var glow: CGFloat = 1.3
        var wing: Wing = .delta
        var engines: Int = 2
        var cockpit: Bool = true
        var fin: Bool = false
        var roofCannon: Bool = false   // dorsal twin cannon on the spine
        var holo: Bool = false         // spinning holographic emitter above the hull
        var texture: UIImage? = nil    // hull panel texture override (Higgsfield)
    }

    // MARK: builders

    /// A classic fighter: spine + nose + swept wings + glowing engines + cockpit.
    static func fighter(_ p: Params) -> SCNNode {
        let root = SCNNode()
        let bodyMat = Synth.mat(p.body, emission: p.accent, glow: 0.18)
        bodyMat.diffuse.contents = p.texture ?? GameFX.hull   // panel/greeble detail (HF per-type)
        bodyMat.diffuse.wrapS = .repeat; bodyMat.diffuse.wrapT = .repeat
        bodyMat.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 2, 1)
        let accentMat = Synth.mat(p.body.mix(p.accent, 0.5), emission: p.accent, glow: p.glow)
        let coreMat = Synth.neon(p.accent); coreMat.emission.intensity = 1.7

        // Fuselage spine.
        root.addChildNode(prim(SCNBox(width: CGFloat(p.width * 0.26), height: 0.34,
                                      length: CGFloat(p.length), chamferRadius: 0.07),
                                bodyMat, SCNVector3(0, 0, 0)))
        // Nose cone (apex forward, −Z).
        root.addChildNode(prim(SCNCone(topRadius: 0, bottomRadius: CGFloat(p.width * 0.16),
                                       height: CGFloat(p.length * 0.55)),
                                accentMat, SCNVector3(0, 0, -p.length * 0.74),
                                euler: SCNVector3(-Float.pi / 2, 0, 0)))
        // Cockpit.
        if p.cockpit {
            root.addChildNode(prim(SCNBox(width: 0.3, height: 0.2, length: 0.62, chamferRadius: 0.08),
                                   coreMat, SCNVector3(0, 0.2, -p.length * 0.12)))
        }
        // Wings (left + right).
        for side: Float in [-1, 1] {
            let wingNode = wing(p, side: side, body: bodyMat, edge: coreMat)
            if let wingNode { root.addChildNode(wingNode) }
        }
        // Engines at the tail, with a neon exhaust core.
        let n = max(1, p.engines)
        for i in 0..<n {
            let t = n == 1 ? 0 : (Float(i) / Float(n - 1) * 2 - 1)
            let x = t * p.width * 0.22
            root.addChildNode(prim(SCNCylinder(radius: 0.14, height: 0.6),
                                   bodyMat, SCNVector3(x, -0.02, p.length * 0.42),
                                   euler: SCNVector3(Float.pi / 2, 0, 0)))
            root.addChildNode(prim(SCNCylinder(radius: 0.11, height: 0.14),
                                   coreMat, SCNVector3(x, -0.02, p.length * 0.52),
                                   euler: SCNVector3(Float.pi / 2, 0, 0)))
        }
        // Dorsal fin.
        if p.fin {
            root.addChildNode(prim(SCNPyramid(width: 0.12, height: 0.5, length: 0.7),
                                   accentMat, SCNVector3(0, 0.25, p.length * 0.25)))
        }
        // Greebles: glowing wingtip pods, belly keel, dorsal block.
        for side: Float in [-1, 1] {
            root.addChildNode(prim(SCNSphere(radius: 0.11), coreMat,
                                   SCNVector3(side * p.width * 0.55, -0.01, p.length * 0.08)))
        }
        root.addChildNode(prim(SCNBox(width: 0.2, height: 0.12, length: CGFloat(p.length * 0.5),
                                      chamferRadius: 0.03),
                               accentMat, SCNVector3(0, -0.17, 0)))
        root.addChildNode(prim(SCNBox(width: 0.14, height: 0.14, length: 0.34, chamferRadius: 0.04),
                               accentMat, SCNVector3(0, 0.23, p.length * 0.06)))
        // Weapons + canopy detail (advanced look, matching the player hull).
        for side: Float in [-1, 1] {
            root.addChildNode(prim(SCNCylinder(radius: 0.05, height: 0.8),
                                   accentMat, SCNVector3(side * p.width * 0.28, -0.1, -p.length * 0.22),
                                   euler: SCNVector3(Float.pi / 2, 0, 0)))             // gun barrel
            root.addChildNode(prim(SCNCylinder(radius: 0.06, height: 0.1),
                                   coreMat, SCNVector3(side * p.width * 0.28, -0.1, -p.length * 0.58),
                                   euler: SCNVector3(Float.pi / 2, 0, 0)))             // glowing muzzle
            root.addChildNode(prim(SCNBox(width: 0.12, height: 0.06, length: CGFloat(p.length * 0.34), chamferRadius: 0.02),
                                   accentMat, SCNVector3(side * p.width * 0.18, 0.12, p.length * 0.05)))  // dorsal strake
        }
        root.addChildNode(prim(SCNBox(width: 0.22, height: 0.14, length: 0.4, chamferRadius: 0.06),
                               coreMat, SCNVector3(0, 0.17, -p.length * 0.04)))        // canopy ridge
        // Dorsal twin cannon on the roof (static → safe to flatten).
        if p.roofCannon {
            root.addChildNode(prim(SCNBox(width: 0.42, height: 0.16, length: 0.5, chamferRadius: 0.05),
                                   accentMat, SCNVector3(0, 0.34, 0)))                 // turret base
            for s: Float in [-1, 1] {
                root.addChildNode(prim(SCNCylinder(radius: 0.05, height: 0.7),
                                       Synth.mat(Synth.gunmetal), SCNVector3(s * 0.14, 0.42, -p.length * 0.22),
                                       euler: SCNVector3(Float.pi / 2, 0, 0)))         // barrel
                root.addChildNode(prim(SCNCylinder(radius: 0.06, height: 0.12),
                                       coreMat, SCNVector3(s * 0.14, 0.42, -p.length * 0.5),
                                       euler: SCNVector3(Float.pi / 2, 0, 0)))         // glowing muzzle
            }
        }
        let flat = finalize(root)
        if p.holo { flat.addChildNode(holoEmitter(p.accent)) }   // animated → added post-flatten
        return flat
    }

    /// A spinning holographic emitter that floats above a hull — a glowing ring with a
    /// pulsing core. Kept out of the flattened mesh so its animation survives.
    static func holoEmitter(_ color: UIColor, height: Float = 0.7) -> SCNNode {
        let n = SCNNode(); n.position = SCNVector3(0, height, 0)
        let ring = SCNTorus(ringRadius: 0.34, pipeRadius: 0.03); ring.firstMaterial = GameFX.additive(color, 1.9)
        let rn = SCNNode(geometry: ring); rn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        rn.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: CGFloat.pi * 2, duration: 1.4)))
        n.addChildNode(rn)
        let core = SCNSphere(radius: 0.1); core.firstMaterial = GameFX.additive(color, 2.4)
        let cn = SCNNode(geometry: core)
        cn.runAction(.repeatForever(.sequence([.scale(to: 1.4, duration: 0.5), .scale(to: 0.8, duration: 0.5)])))
        n.addChildNode(cn)
        return n
    }

    /// The hero player hull: a sleek silver fighter with armour plates, gun barrels,
    /// panel creases and glowing teal trim — more detailed than the enemy fighters. The
    /// spinning weapon-ring + thrust flames are added by GameFX at assembly time.
    static func playerHull(accent: UIColor) -> SCNNode {
        let root = SCNNode()
        let body = Synth.metal(Synth.silver)
        body.diffuse.contents = GameFX.hull   // panel/greeble detail (sx-hull.png)
        body.diffuse.wrapS = .repeat; body.diffuse.wrapT = .repeat
        let plate = Synth.metal(Synth.silver.mix(.black, 0.22))   // darker armour
        let crease = Synth.mat(Synth.gunmetal)                    // creases / weapons
        let trim = Synth.neon(accent); trim.emission.intensity = 1.9
        let canopy = Synth.neon(accent.mix(.white, 0.3)); canopy.emission.intensity = 1.4
        let L: Float = 2.6, W: Float = 2.4

        // Fuselage (layered for a dorsal crease).
        root.addChildNode(prim(SCNBox(width: 0.5, height: 0.34, length: CGFloat(L), chamferRadius: 0.08),
                               body, SCNVector3(0, 0, 0)))
        root.addChildNode(prim(SCNBox(width: 0.34, height: 0.12, length: CGFloat(L * 0.9), chamferRadius: 0.04),
                               crease, SCNVector3(0, 0.2, 0)))
        // Sharp nose + glowing tip.
        root.addChildNode(prim(SCNCone(topRadius: 0, bottomRadius: 0.26, height: CGFloat(L * 0.6)),
                               body, SCNVector3(0, 0, -L * 0.78), euler: SCNVector3(-Float.pi / 2, 0, 0)))
        root.addChildNode(prim(SCNCone(topRadius: 0, bottomRadius: 0.1, height: 0.5),
                               trim, SCNVector3(0, 0, -L * 0.96), euler: SCNVector3(-Float.pi / 2, 0, 0)))
        // Canopy.
        root.addChildNode(prim(SCNBox(width: 0.26, height: 0.2, length: 0.6, chamferRadius: 0.1),
                               canopy, SCNVector3(0, 0.22, -L * 0.16)))
        // Swept wings: armour plate + glowing leading edge + tip pod + gun barrel.
        for side: Float in [-1, 1] {
            let plateGeo = SCNBox(width: CGFloat(W * 0.5), height: 0.08, length: CGFloat(L * 0.5), chamferRadius: 0.03)
            let w = prim(plateGeo, plate, SCNVector3(side * W * 0.34, -0.02, L * 0.06))
            w.eulerAngles = SCNVector3(0, side * 0.8, side * -0.08)
            root.addChildNode(w)
            let edge = prim(SCNBox(width: CGFloat(W * 0.5), height: 0.05, length: 0.06, chamferRadius: 0.02),
                            trim, SCNVector3(side * W * 0.34, 0.02, L * 0.06 - L * 0.24))
            edge.eulerAngles = w.eulerAngles
            root.addChildNode(edge)
            root.addChildNode(prim(SCNBox(width: 0.16, height: 0.14, length: 0.5, chamferRadius: 0.05),
                                   plate, SCNVector3(side * W * 0.58, 0, L * 0.02)))
            root.addChildNode(prim(SCNCylinder(radius: 0.06, height: 1.1),
                                   crease, SCNVector3(side * W * 0.3, -0.12, -L * 0.2),
                                   euler: SCNVector3(Float.pi / 2, 0, 0)))
            root.addChildNode(prim(SCNCylinder(radius: 0.07, height: 0.14),
                                   trim, SCNVector3(side * W * 0.3, -0.12, -L * 0.72),
                                   euler: SCNVector3(Float.pi / 2, 0, 0)))
        }
        // Rear armour block + dorsal fin.
        root.addChildNode(prim(SCNBox(width: 0.44, height: 0.26, length: 0.5, chamferRadius: 0.06),
                               plate, SCNVector3(0, 0.04, L * 0.42)))
        root.addChildNode(prim(SCNPyramid(width: 0.1, height: 0.55, length: 0.7),
                               trim, SCNVector3(0, 0.26, L * 0.28)))
        return finalize(root)
    }

    /// A hovering saucer / disc enemy.
    static func saucer(body: UIColor, accent: UIColor, glow: CGFloat = 1.4,
                       holo: Bool = false, texture: UIImage? = nil) -> SCNNode {
        let root = SCNNode()
        let discMat = Synth.mat(body, emission: accent, glow: 0.1)
        if let texture { discMat.diffuse.contents = texture; discMat.diffuse.wrapS = .repeat; discMat.diffuse.wrapT = .repeat }
        root.addChildNode(prim(SCNCylinder(radius: 1.05, height: 0.28), discMat, SCNVector3Zero))
        root.addChildNode(prim(SCNSphere(radius: 0.5),
                               Synth.neon(accent), SCNVector3(0, 0.22, 0)))
        // Ring of glowing pods underneath.
        for i in 0..<6 {
            let a = Float(i) / 6 * 2 * Float.pi
            root.addChildNode(prim(SCNSphere(radius: 0.12), Synth.neon(accent),
                                   SCNVector3(cos(a) * 0.85, -0.12, sin(a) * 0.85)))
        }
        let flat = finalize(root)
        if holo { flat.addChildNode(holoEmitter(accent, height: 0.85)) }
        return flat
    }

    /// A small spinning drone / mine.
    static func drone(accent: UIColor, holo: Bool = false) -> SCNNode {
        let root = SCNNode()
        root.addChildNode(prim(SCNBox(width: 0.5, height: 0.5, length: 0.5, chamferRadius: 0.12),
                               Synth.mat(Synth.hullSteel, emission: accent, glow: 0.2), SCNVector3Zero))
        for axis in 0..<3 {
            let e = SCNVector3(axis == 0 ? Float.pi / 2 : 0, axis == 1 ? Float.pi / 2 : 0, 0)
            root.addChildNode(prim(SCNTorus(ringRadius: 0.55, pipeRadius: 0.04),
                                   Synth.neon(accent), SCNVector3Zero, euler: e))
        }
        let flat = finalize(root)
        if holo { flat.addChildNode(holoEmitter(accent, height: 0.6)) }
        return flat
    }

    /// A large, detailed capital-ship boss: central hull + glowing core, side pods with
    /// turrets, swept wings, forward prongs, a dorsal fin and an armour ring. `variant`
    /// nudges the silhouette so the four bosses differ.
    static func boss(accent: UIColor, variant: Int) -> SCNNode {
        let root = SCNNode()
        let body = Synth.metal(Synth.hullSteel.mix(.black, 0.1))
        body.diffuse.contents = GameFX.hull
        body.diffuse.wrapS = .repeat; body.diffuse.wrapT = .repeat
        let dark = Synth.mat(Synth.gunmetal)
        let trim = Synth.neon(accent); trim.emission.intensity = 2.0
        let core = Synth.neon(accent); core.emission.intensity = 2.6
        let W: Float = 7, L: Float = 6

        // Central hull + glowing reactor core.
        root.addChildNode(prim(SCNBox(width: CGFloat(W * 0.32), height: 1.1, length: CGFloat(L), chamferRadius: 0.22), body, SCNVector3Zero))
        root.addChildNode(prim(SCNBox(width: CGFloat(W * 0.2), height: 0.5, length: CGFloat(L * 0.9), chamferRadius: 0.1), dark, SCNVector3(0, 0.55, 0)))
        root.addChildNode(prim(SCNSphere(radius: 0.8), core, SCNVector3(0, 0.35, -L * 0.08)))
        root.addChildNode(prim(SCNTorus(ringRadius: 1.0, pipeRadius: 0.08), trim, SCNVector3(0, 0.35, -L * 0.08), euler: SCNVector3(Float.pi / 2, 0, 0)))

        for side: Float in [-1, 1] {
            // Side pod + barrel turret.
            root.addChildNode(prim(SCNBox(width: 1.3, height: 0.9, length: CGFloat(L * 0.8), chamferRadius: 0.16), body, SCNVector3(side * W * 0.34, 0, 0)))
            root.addChildNode(prim(SCNCylinder(radius: 0.26, height: 1.3), dark, SCNVector3(side * W * 0.34, 0.5, -L * 0.3), euler: SCNVector3(Float.pi / 2, 0, 0)))
            root.addChildNode(prim(SCNCylinder(radius: 0.3, height: 0.22), trim, SCNVector3(side * W * 0.34, 0.5, -L * 0.62), euler: SCNVector3(Float.pi / 2, 0, 0)))
            // Swept wing + glowing tip.
            let wing = prim(SCNBox(width: CGFloat(W * 0.42), height: 0.22, length: CGFloat(L * 0.5), chamferRadius: 0.1), body, SCNVector3(side * W * 0.52, 0, L * 0.12))
            wing.eulerAngles = SCNVector3(0, side * 0.55, side * -0.08)
            root.addChildNode(wing)
            root.addChildNode(prim(SCNSphere(radius: 0.32), trim, SCNVector3(side * W * 0.74, 0, L * 0.12)))
            // Forward prong.
            root.addChildNode(prim(SCNCone(topRadius: 0, bottomRadius: 0.4, height: CGFloat(L * (0.6 + Float(variant % 2) * 0.25))), trim, SCNVector3(side * W * 0.2, 0, -L * 0.72), euler: SCNVector3(-Float.pi / 2, 0, 0)))
        }
        // Dorsal fin + antenna.
        root.addChildNode(prim(SCNPyramid(width: 0.45, height: 1.6, length: 1.6), trim, SCNVector3(0, 0.7, L * 0.3)))
        // Armour ring of greeble blocks on the spine.
        let rings = 5 + variant % 3
        for i in 0..<rings {
            let a = Float(i) / Float(rings) * 2 * Float.pi
            root.addChildNode(prim(SCNBox(width: 0.5, height: 0.3, length: 0.5, chamferRadius: 0.08), dark, SCNVector3(cos(a) * 1.3, 0.55, sin(a) * 1.1 - L * 0.05)))
        }
        return finalize(root)
    }

    // MARK: helpers

    private static func wing(_ p: ShipKit.Params, side: Float, body: SCNMaterial, edge: SCNMaterial) -> SCNNode? {
        guard p.wing != .none else { return nil }
        let span = p.width * 0.5
        let node = SCNNode()
        let plate = prim(SCNBox(width: CGFloat(span), height: 0.07, length: CGFloat(p.length * 0.5), chamferRadius: 0.03),
                         body, SCNVector3(side * span * 0.55, -0.02, p.length * 0.08))
        // Sweep / dihedral by wing style.
        switch p.wing {
        case .delta:   plate.eulerAngles = SCNVector3(0, side * 0.5, 0)
        case .swept:   plate.eulerAngles = SCNVector3(0, side * 0.85, side * -0.12)
        case .forward: plate.eulerAngles = SCNVector3(0, side * -0.6, side * 0.1)
        case .none:    break
        }
        node.addChildNode(plate)
        // Neon leading-edge strip.
        let strip = prim(SCNBox(width: CGFloat(span), height: 0.05, length: 0.07, chamferRadius: 0.02),
                         edge, SCNVector3(side * span * 0.55, 0.01, p.length * 0.08 - p.length * 0.24))
        strip.eulerAngles = plate.eulerAngles
        node.addChildNode(strip)
        return node
    }

    private static func prim(_ geo: SCNGeometry, _ mat: SCNMaterial, _ pos: SCNVector3,
                             euler: SCNVector3 = SCNVector3Zero) -> SCNNode {
        geo.firstMaterial = mat
        let n = SCNNode(geometry: geo)
        n.position = pos
        n.eulerAngles = euler
        return n
    }

    /// Merge the assembled primitives into one node for cheap drawing.
    private static func finalize(_ root: SCNNode) -> SCNNode {
        let flat = root.flattenedClone()
        return flat
    }
}

extension UIColor {
    /// Linear mix toward another colour (0 = self, 1 = other).
    func mix(_ other: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                       blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
