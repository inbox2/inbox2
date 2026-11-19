import SceneKit
import UIKit

// Shader-heavy game FX for NEON STRIKE: additive glow materials, laser-beam bolts,
// muzzle/impact flashes, and orb-style plasma explosions (an fbm domain-warp surface
// shader modifier over an additive plasma quad + shockwave ring + flash + sparks).
// Everything leans on the camera's HDR bloom (see GameScene.setupScene) so emissive
// neon blooms like the Bridge orb.
//
// Higgsfield textures drop in by name when present: `sx-hull.png` (ship hull) and
// `sx-plasma.png` (explosion core) override the procedural fallbacks below.

enum GameArt {
    private static var cache: [String: UIImage] = [:]
    /// A bundled loose PNG (e.g. a Higgsfield texture), or nil if not shipped.
    static func bundled(_ name: String) -> UIImage? {
        if let hit = cache[name] { return hit }
        guard let path = Bundle.main.path(forResource: name, ofType: "png"),
              let img = UIImage(contentsOfFile: path) else { return nil }
        cache[name] = img
        return img
    }
}

enum GameFX {
    // MARK: textures (Higgsfield override → procedural fallback)
    static let hull: UIImage = GameArt.bundled("sx-hull") ?? proceduralHull()
    static let plasma: UIImage = GameArt.bundled("sx-plasma") ?? proceduralPlasma()
    static let glow: UIImage = TextureGen.dot(.white, size: 64)
    static let mushroom: UIImage? = GameArt.bundled("sx-mushroom")   // bomb nuclear cloud
    static let hblast: UIImage? = GameArt.bundled("sx-hblast")       // bomb horizontal shockwave
    static let enemyHullA: UIImage? = GameArt.bundled("sx-enemy-a")  // per-type enemy hull textures
    static let enemyHullB: UIImage? = GameArt.bundled("sx-enemy-b")
    static let enemyHullC: UIImage? = GameArt.bundled("sx-enemy-c")

    // MARK: materials

    /// A self-lit additive material — only its emission adds to the frame, so black is
    /// transparent and bright neon blooms. Used for bolts, flashes, rings, plasma.
    static func additive(_ color: UIColor, _ intensity: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.emission.contents = color
        m.emission.intensity = intensity
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    /// Additive material whose emission is a glowing-on-black texture (Higgsfield FX
    /// sprite): black contributes nothing under `.add`, so only the bright art shows.
    static func additiveTextured(_ img: UIImage, _ intensity: CGFloat = 1.4) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.emission.contents = img
        m.emission.intensity = intensity
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    // MARK: laser bolts

    /// Player laser: white-hot core inside a coloured glow sheath, streak along local Z.
    static func playerBolt(_ color: UIColor = Synth.teal) -> SCNNode { bolt(glow: color, length: 2.6, radius: 0.17) }
    static func enemyBolt(_ color: UIColor) -> SCNNode { bolt(glow: color, length: 1.8, radius: 0.16) }

    /// A homing rocket: silver body + glowing nose + fins + an orange spark/exhaust trail.
    static func rocket(_ color: UIColor) -> SCNNode {
        let n = SCNNode()
        let body = SCNCylinder(radius: 0.1, height: 0.6); body.firstMaterial = Synth.metal(Synth.silver)
        let bn = SCNNode(geometry: body); bn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0); n.addChildNode(bn)
        let nose = SCNCone(topRadius: 0, bottomRadius: 0.1, height: 0.3); nose.firstMaterial = Synth.neon(color)
        let nn = SCNNode(geometry: nose); nn.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        nn.position = SCNVector3(0, 0, -0.42); n.addChildNode(nn)
        for s: Float in [-1, 1] {
            let fin = SCNBox(width: 0.04, height: 0.22, length: 0.18, chamferRadius: 0.01)
            fin.firstMaterial = additive(color, 1.2)
            let fn = SCNNode(geometry: fin); fn.position = SCNVector3(s * 0.12, 0, 0.26)
            n.addChildNode(fn)
        }
        let ex = SCNSphere(radius: 0.12); ex.firstMaterial = additive(Synth.orange, 2.2)
        let en = SCNNode(geometry: ex); en.position = SCNVector3(0, 0, 0.34)
        n.addChildNode(en)
        let ps = SCNParticleSystem()
        ps.particleImage = glow; ps.birthRate = 110; ps.particleLifeSpan = 0.22
        ps.particleVelocity = 5; ps.emittingDirection = SCNVector3(0, 0, 1); ps.spreadingAngle = 14
        ps.particleSize = 0.13; ps.particleColor = Synth.orange
        ps.particleColorVariation = SCNVector4(0.1, 0.1, 0, 0); ps.blendMode = .additive; ps.isLightingEnabled = false
        let pn = SCNNode(); pn.position = SCNVector3(0, 0, 0.3); pn.addParticleSystem(ps); n.addChildNode(pn)
        return n
    }

    /// A fat piercing beam-bolt wrapped in additive sparks.
    static func beamBolt(_ color: UIColor) -> SCNNode {
        let n = bolt(glow: color, length: 3.4, radius: 0.26)
        let ps = SCNParticleSystem()
        ps.particleImage = glow; ps.birthRate = 70; ps.particleLifeSpan = 0.16
        ps.particleVelocity = 4; ps.spreadingAngle = 180; ps.particleSize = 0.1
        ps.particleColor = color; ps.blendMode = .additive; ps.isLightingEnabled = false
        let pn = SCNNode(); pn.addParticleSystem(ps); n.addChildNode(pn)
        return n
    }

    /// The OVERDRIVE super-beam: a thick white-cored beam down the lane wrapped in
    /// spinning particle rings — sweeps across the screen destroying everything.
    static func superBeam(_ color: UIColor, length: Float = 84) -> SCNNode {
        let n = SCNNode()
        let core = SCNCylinder(radius: 0.38, height: CGFloat(length)); core.firstMaterial = additive(.white, 2.8)
        let cn = SCNNode(geometry: core); cn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        cn.position = SCNVector3(0, 0, -length / 2); n.addChildNode(cn)
        let outer = SCNCylinder(radius: 0.85, height: CGFloat(length)); outer.firstMaterial = additive(color, 1.8)
        let on = SCNNode(geometry: outer); on.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        on.position = SCNVector3(0, 0, -length / 2); n.addChildNode(on)
        // Spinning particle rings orbiting the beam axis.
        let spin = SCNNode()
        for z: Float in [-6, -16, -28, -42, -58, -74] {
            for i in 0..<6 {
                let a = Float(i) / 6 * 2 * Float.pi
                let s = SCNSphere(radius: 0.16); s.firstMaterial = additive(color, 2.2)
                let sn = SCNNode(geometry: s); sn.position = SCNVector3(cos(a) * 1.15, sin(a) * 1.15, z)
                spin.addChildNode(sn)
            }
        }
        spin.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: CGFloat.pi * 2, duration: 0.4)))
        n.addChildNode(spin)
        return n
    }

    /// Holographic shimmering steel wall raised in front of the ship by the shield button.
    /// An additive translucent pane (scrolling scanlines + sweep via the shader) inside a
    /// glowing frame; deploys with a quick vertical "open" pop.
    static func barrierWall(_ color: UIColor = Synth.aqua) -> SCNNode {
        let n = SCNNode()
        let w: CGFloat = 3.4, h: CGFloat = 3.0
        let pane = SCNPlane(width: w, height: h); pane.cornerRadius = 0.35
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        m.shaderModifiers = [.surface: barrierShimmerModifier]
        pane.firstMaterial = m
        n.addChildNode(SCNNode(geometry: pane))
        // Glowing steel frame (four thin additive bars).
        let fw: CGFloat = 0.09
        for (px, py, bw, bh): (CGFloat, CGFloat, CGFloat, CGFloat) in
            [(0, h / 2, w, fw), (0, -h / 2, w, fw), (-w / 2, 0, fw, h), (w / 2, 0, fw, h)] {
            let bar = SCNPlane(width: bw, height: bh); bar.firstMaterial = additive(color, 2.0)
            let bn = SCNNode(geometry: bar); bn.position = SCNVector3(Float(px), Float(py), 0.02)
            n.addChildNode(bn)
        }
        n.scale = SCNVector3(1, 0.18, 1)
        n.runAction(.scale(to: 1, duration: 0.14))   // open vertically on deploy
        return n
    }

    static let barrierShimmerModifier = """
    #pragma body
    float2 uv = _surface.diffuseTexcoord;
    float t = scn_frame.time;
    float scan = 0.5 + 0.5 * sin(uv.y * 26.0 - t * 8.0);
    float sweep = 0.5 + 0.5 * sin(uv.x * 6.2832 - t * 3.0);
    float edge = smoothstep(0.0, 0.12, uv.x) * smoothstep(1.0, 0.88, uv.x)
               * smoothstep(0.0, 0.12, uv.y) * smoothstep(1.0, 0.88, uv.y);
    float fill = 0.16 + 0.22 * scan + 0.16 * sweep;
    float3 steel = float3(0.55, 0.8, 1.0);
    _surface.emission = float4(steel * fill * (0.5 + 0.5 * edge), 1.0);
    _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
    """

    private static func bolt(glow: UIColor, length: Float, radius: Float) -> SCNNode {
        let n = SCNNode()
        // Outer glow sheath.
        let sheath = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        sheath.firstMaterial = additive(glow, 1.6)
        let sn = SCNNode(geometry: sheath); sn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        n.addChildNode(sn)
        // Bright white core.
        let core = SCNCylinder(radius: CGFloat(radius * 0.42), height: CGFloat(length * 0.96))
        core.firstMaterial = additive(Synth.white, 2.4)
        let cn = SCNNode(geometry: core); cn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        n.addChildNode(cn)
        // Rounded cap glints.
        let cap = SCNSphere(radius: CGFloat(radius * 0.6)); cap.firstMaterial = additive(glow, 2.0)
        let capN = SCNNode(geometry: cap); capN.position = SCNVector3(0, 0, -length * 0.5)
        n.addChildNode(capN)
        return n
    }

    // MARK: flashes

    /// A quick billboarded additive flash that scales up and fades out.
    static func flash(_ color: UIColor, scale: CGFloat, life: TimeInterval = 0.18) -> SCNNode {
        let p = SCNPlane(width: 1, height: 1)
        let m = additive(.white, 1.6)
        m.emission.contents = glow
        m.multiply.contents = color
        p.firstMaterial = m
        let n = SCNNode(geometry: p)
        n.constraints = [SCNBillboardConstraint()]
        n.scale = SCNVector3(scale * 0.3, scale * 0.3, scale * 0.3)
        n.runAction(.sequence([
            .group([.scale(to: scale, duration: life), .fadeOut(duration: life)]),
            .removeFromParentNode(),
        ]))
        return n
    }

    // MARK: explosions

    /// A layered, shader-heavy burst: orb-style plasma quad + shockwave ring + flash +
    /// spark particles. `scale` ~ blast radius (1 = normal enemy, 4 = boss).
    static func explosion(color: UIColor, scale: CGFloat) -> SCNNode {
        let root = SCNNode()
        let scale = scale * CGFloat.random(in: 0.82...1.22)   // per-blast size variety
        // Particle size grows only gently with blast size so big blasts don't white out.
        let sz = 0.6 + min(scale, 4) * 0.18

        // 1. Quick flash.
        root.addChildNode(flash(.white, scale: scale * 1.1, life: 0.12))

        // 2. Roiling fire core (fbm surface shader over the plasma texture; the texture
        //    is the graceful fallback if the modifier fails to compile).
        let quad = SCNPlane(width: 1, height: 1)
        let pm = additive(.white, 1.4)
        pm.emission.contents = plasma   // Higgsfield fire-core texture (sx-plasma.png)
        let a = Float.random(in: 0...6.283)   // rotate the fire core so no two blasts match
        pm.emission.contentsTransform = SCNMatrix4Mult(
            SCNMatrix4Mult(SCNMatrix4MakeTranslation(-0.5, -0.5, 0), SCNMatrix4MakeRotation(a, 0, 0, 1)),
            SCNMatrix4MakeTranslation(0.5, 0.5, 0))
        quad.firstMaterial = pm
        let qn = SCNNode(geometry: quad)
        qn.constraints = [SCNBillboardConstraint()]
        qn.scale = SCNVector3(scale * 0.5, scale * 0.5, scale * 0.5)
        qn.opacity = 0.9
        qn.runAction(.sequence([
            .group([.scale(to: scale * 1.7, duration: 0.5), .fadeOut(duration: 0.55)]),
            .removeFromParentNode(),
        ]))
        root.addChildNode(qn)

        // 3. Expanding shockwave ring.
        let ring = SCNTorus(ringRadius: 0.5, pipeRadius: 0.05)
        ring.firstMaterial = additive(Synth.orange, 1.6)
        let rn = SCNNode(geometry: ring)
        rn.constraints = [SCNBillboardConstraint()]
        rn.scale = SCNVector3(scale * 0.2, scale * 0.2, scale * 0.2)
        rn.runAction(.sequence([
            .group([.scale(to: scale * 1.7, duration: 0.5), .fadeOut(duration: 0.55)]),
            .removeFromParentNode(),
        ]))
        root.addChildNode(rn)

        // 4. Layered fire particles: orange flames, rising red embers, a few accent sparks,
        //    and just a pinch of white at the core.
        for ps in [fireBurst(Synth.orange, scale: scale, speed: 10, size: sz * 0.16, count: 34, life: 0.6),
                   fireBurst(Synth.red, scale: scale, speed: 6, size: sz * 0.18, count: 26, life: 0.95, rise: true),
                   fireBurst(color, scale: scale, speed: 12, size: sz * 0.12, count: 18, life: 0.5),
                   fireBurst(.white, scale: scale, speed: 14, size: sz * 0.09, count: 10, life: 0.3)] {
            let n = SCNNode(); n.addParticleSystem(ps); root.addChildNode(n)
        }

        root.runAction(.sequence([.wait(duration: 1.5), .removeFromParentNode()]))
        return root
    }

    private static func fireBurst(_ color: UIColor, scale: CGFloat, speed: CGFloat, size: CGFloat,
                                  count: CGFloat, life: CGFloat, rise: Bool = false) -> SCNParticleSystem {
        let ps = SCNParticleSystem()
        ps.particleImage = glow
        ps.emissionDuration = 0.05
        ps.loops = false
        ps.particleLifeSpan = life
        ps.particleLifeSpanVariation = life * 0.5
        ps.particleVelocity = speed * scale
        ps.particleVelocityVariation = speed * scale * 0.8
        ps.spreadingAngle = 180
        ps.particleSize = size
        ps.particleSizeVariation = size * 0.6
        ps.particleColor = color
        ps.particleColorVariation = SCNVector4(0.08, 0.12, 0.06, 0)
        ps.blendMode = .additive
        ps.isLightingEnabled = false
        if rise { ps.acceleration = SCNVector3(0, 5, 0) }   // embers drift upward
        ps.birthRate = (count * min(scale, 3)) / CGFloat(ps.emissionDuration)
        return ps
    }

    // MARK: bomb (thrown projectile + blast)

    /// A lobbed bomb: gunmetal core inside a pulsing magenta shell, a spinning cyan ring,
    /// and a magenta spark trail streaming off the back (+Z).
    static func bombProjectile() -> SCNNode {
        let n = SCNNode()
        let core = SCNSphere(radius: 0.2); core.firstMaterial = Synth.metal(Synth.gunmetal)
        n.addChildNode(SCNNode(geometry: core))
        let shell = SCNSphere(radius: 0.26); shell.firstMaterial = additive(Synth.magenta, 1.7)
        let sh = SCNNode(geometry: shell)
        sh.runAction(.repeatForever(.sequence([.scale(to: 1.22, duration: 0.16), .scale(to: 0.9, duration: 0.16)])))
        n.addChildNode(sh)
        let ring = SCNTorus(ringRadius: 0.34, pipeRadius: 0.045); ring.firstMaterial = additive(Synth.cyan, 1.9)
        let rn = SCNNode(geometry: ring); rn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        rn.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: CGFloat.pi * 2, duration: 0.5)))
        n.addChildNode(rn)
        let ps = SCNParticleSystem()
        ps.particleImage = glow; ps.birthRate = 200; ps.particleLifeSpan = 0.32
        ps.particleVelocity = 4; ps.emittingDirection = SCNVector3(0, 0, 1); ps.spreadingAngle = 16
        ps.particleSize = 0.12; ps.particleColor = Synth.magenta
        ps.blendMode = .additive; ps.isLightingEnabled = false
        let pn = SCNNode(); pn.position = SCNVector3(0, 0, 0.32); pn.addParticleSystem(ps); n.addChildNode(pn)
        return n
    }

    /// A wide horizontal shockwave (Higgsfield `sx-hblast` sprite, billboarded upright so
    /// it always faces the camera) that snaps wide and fades — the bomb's lateral wipe.
    static func horizontalBlast(width: Float) -> SCNNode {
        let root = SCNNode()
        let h = width * (768.0 / 1376.0)
        let plane = SCNPlane(width: CGFloat(width), height: CGFloat(h))
        plane.firstMaterial = hblast.map { additiveTextured($0, 1.7) } ?? {
            let m = additive(Synth.orange, 1.6); m.emission.contents = glow; return m
        }()
        let pn = SCNNode(geometry: plane)
        let bc = SCNBillboardConstraint(); bc.freeAxes = .Y; pn.constraints = [bc]
        pn.renderingOrder = 10
        pn.scale = SCNVector3(0.35, 0.55, 1)
        pn.runAction(.sequence([
            .group([.scale(to: 1.0, duration: 0.42), .fadeOut(duration: 0.5)]),
            .removeFromParentNode(),
        ]))
        root.addChildNode(pn)
        // A cyan shockwave ring under it for extra lateral punch.
        let ring = SCNTorus(ringRadius: 0.5, pipeRadius: 0.06); ring.firstMaterial = additive(Synth.cyan, 1.6)
        let rn = SCNNode(geometry: ring); let bc2 = SCNBillboardConstraint(); bc2.freeAxes = .Y; rn.constraints = [bc2]
        rn.scale = SCNVector3(width * 0.1, width * 0.1, width * 0.1)
        rn.runAction(.sequence([
            .group([.scale(to: CGFloat(width) * 0.5, duration: 0.5), .fadeOut(duration: 0.55)]),
            .removeFromParentNode(),
        ]))
        root.addChildNode(rn)
        root.runAction(.sequence([.wait(duration: 1.2), .removeFromParentNode()]))
        return root
    }

    /// A small rising mushroom cloud (Higgsfield `sx-mushroom` sprite). The art's hot core
    /// sits in its lower third, so the quad is lifted to seat that core at the blast point,
    /// then the cloud billows up and fades.
    static func mushroomCloud(scale: CGFloat) -> SCNNode {
        let root = SCNNode()
        let plane = SCNPlane(width: scale, height: scale)
        plane.firstMaterial = mushroom.map { additiveTextured($0, 1.7) } ?? additive(Synth.magenta, 1.5)
        let pn = SCNNode(geometry: plane)
        let bc = SCNBillboardConstraint(); bc.freeAxes = .Y; pn.constraints = [bc]
        pn.renderingOrder = 11
        pn.position = SCNVector3(0, Float(scale) * 0.32, 0)
        pn.scale = SCNVector3(0.45, 0.35, 1)
        pn.runAction(.sequence([
            .group([.scale(to: 1.0, duration: 0.5),
                    .moveBy(x: 0, y: CGFloat(Float(scale) * 0.45), z: 0, duration: 1.5)]),
            .fadeOut(duration: 0.7),
            .removeFromParentNode(),
        ]))
        root.addChildNode(pn)
        root.runAction(.sequence([.wait(duration: 2.8), .removeFromParentNode()]))
        return root
    }

    /// The player ship blown into ~13 tumbling fragments that drift outward and slowly
    /// coast to a stop (easeOut) — they keep spinning forever so they float behind the
    /// GAME OVER overlay. Caller offsets each piece from the death position.
    static func shipDebris(accent: UIColor, scale: Float = 1) -> [SCNNode] {
        var pieces: [SCNNode] = []
        let mats = [Synth.metal(Synth.silver),
                    Synth.metal(Synth.silver.mix(.black, 0.22)),
                    Synth.mat(Synth.gunmetal),
                    Synth.neon(accent)]
        let geos: [() -> SCNGeometry] = [
            { SCNBox(width: 0.32, height: 0.12, length: 0.5, chamferRadius: 0.03) },
            { SCNCone(topRadius: 0, bottomRadius: 0.16, height: 0.42) },
            { SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0.04) },
            { SCNCylinder(radius: 0.06, height: 0.5) },
        ]
        for i in 0..<13 {
            let g = geos[i % geos.count](); g.firstMaterial = mats[i % mats.count]
            let node = SCNNode(geometry: g)
            node.scale = SCNVector3(scale, scale, scale)
            let ox = Float.random(in: -0.4...0.4) * scale
            let oy = Float.random(in: -0.3...0.3) * scale
            let oz = Float.random(in: -0.4...0.4) * scale
            node.position = SCNVector3(ox, oy, oz)
            let dir = SCNVector3(ox, oy + 0.25, oz).normalized
            let dist = Float.random(in: 2.5...6)
            let move = SCNAction.move(by: SCNVector3(dir.x * dist + Float.random(in: -1...1),
                                                     dir.y * dist + Float.random(in: 0...1.6),
                                                     dir.z * dist + Float.random(in: -1...1)),
                                      duration: Double.random(in: 5...9))
            move.timingMode = .easeOut
            node.runAction(move)
            node.runAction(.repeatForever(.rotateBy(x: CGFloat.random(in: -3...3),
                                                     y: CGFloat.random(in: -3...3),
                                                     z: CGFloat.random(in: -3...3),
                                                     duration: Double.random(in: 1.2...2.6))))
            pieces.append(node)
        }
        return pieces
    }

    // MARK: player craft adornments

    /// A spinning weapon-ring that orbits the player (glowing torus + silver weapon pods).
    static func orbitRing(color: UIColor, radius: Float = 1.7) -> SCNNode {
        let ring = SCNNode()
        let torus = SCNTorus(ringRadius: CGFloat(radius), pipeRadius: 0.06)
        torus.firstMaterial = additive(color, 1.8)
        let tn = SCNNode(geometry: torus)
        tn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)   // lie flat around the ship
        ring.addChildNode(tn)
        let podMat = Synth.metal(Synth.silver)
        for i in 0..<4 {
            let a = Float(i) / 4 * 2 * Float.pi
            let pod = SCNNode(geometry: SCNBox(width: 0.2, height: 0.14, length: 0.34, chamferRadius: 0.04))
            pod.geometry?.firstMaterial = podMat
            pod.position = SCNVector3(cos(a) * radius, 0, sin(a) * radius)
            ring.addChildNode(pod)
            let tip = SCNNode(geometry: SCNSphere(radius: 0.08))
            tip.geometry?.firstMaterial = additive(color, 2.0)
            tip.position = SCNVector3(cos(a) * (radius + 0.18), 0, sin(a) * (radius + 0.18))
            ring.addChildNode(tip)
        }
        ring.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 3.2)))
        return ring
    }

    /// A pulsing weak-point orb — a boss's only damageable hitbox (Contra-style). Bright
    /// white-hot core in a coloured shell + halo, throbbing so it reads as "shoot here".
    static func weakOrb(_ color: UIColor) -> SCNNode {
        let n = SCNNode()
        n.renderingOrder = 8   // draw over the hull
        let shell = SCNSphere(radius: 0.55); shell.firstMaterial = additive(color, 2.4)
        n.addChildNode(SCNNode(geometry: shell))
        let core = SCNSphere(radius: 0.3); core.firstMaterial = additive(.white, 2.8)
        n.addChildNode(SCNNode(geometry: core))
        let halo = SCNTorus(ringRadius: 0.78, pipeRadius: 0.06); halo.firstMaterial = additive(color, 1.8)
        let hn = SCNNode(geometry: halo); hn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        hn.runAction(.repeatForever(.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 2.2)))
        n.addChildNode(hn)
        n.runAction(.repeatForever(.sequence([.scale(to: 1.18, duration: 0.5), .scale(to: 0.88, duration: 0.5)])))
        return n
    }

    /// A bolt-on weapon pod that attaches around the ship: a metal mount + glowing collar,
    /// and either a single barrel (guns) or a twin-missile rack (`missile`). Faces −Z.
    static func weaponPod(_ color: UIColor, missile: Bool = false) -> SCNNode {
        let n = SCNNode()
        let base = SCNBox(width: 0.22, height: 0.18, length: 0.5, chamferRadius: 0.04)
        base.firstMaterial = Synth.metal(Synth.silver.mix(.black, 0.2))
        n.addChildNode(SCNNode(geometry: base))
        if missile {
            for s: Float in [-1, 1] {
                let tube = SCNCylinder(radius: 0.05, height: 0.34); tube.firstMaterial = Synth.metal(Synth.silver)
                let tn = SCNNode(geometry: tube); tn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
                tn.position = SCNVector3(s * 0.07, 0.08, -0.2); n.addChildNode(tn)
                let tip = SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.12); tip.firstMaterial = additive(color, 2.0)
                let pn = SCNNode(geometry: tip); pn.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
                pn.position = SCNVector3(s * 0.07, 0.08, -0.42); n.addChildNode(pn)
            }
        } else {
            let barrel = SCNCylinder(radius: 0.05, height: 0.6); barrel.firstMaterial = Synth.mat(Synth.gunmetal)
            let bn = SCNNode(geometry: barrel); bn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            bn.position = SCNVector3(0, 0, -0.35); n.addChildNode(bn)
            let tip = SCNSphere(radius: 0.07); tip.firstMaterial = additive(color, 2.2)
            let tn = SCNNode(geometry: tip); tn.position = SCNVector3(0, 0, -0.66); n.addChildNode(tn)
        }
        let collar = SCNTorus(ringRadius: 0.14, pipeRadius: 0.02); collar.firstMaterial = additive(color, 1.6)
        let cn = SCNNode(geometry: collar); cn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0); n.addChildNode(cn)
        return n
    }

    /// A flickering thrust flame (additive cone + bright core) pointing backward (+Z).
    static func thruster(color: UIColor = Synth.orange) -> SCNNode {
        let t = SCNNode()
        let cone = SCNCone(topRadius: 0.02, bottomRadius: 0.17, height: 1.0)
        cone.firstMaterial = additive(color, 2.0)
        let cn = SCNNode(geometry: cone)
        cn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)   // apex → +Z (back)
        cn.position = SCNVector3(0, 0, 0.5)
        t.addChildNode(cn)
        let core = SCNCone(topRadius: 0.01, bottomRadius: 0.09, height: 0.8)
        core.firstMaterial = additive(.white, 2.6)
        let coreN = SCNNode(geometry: core)
        coreN.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        coreN.position = SCNVector3(0, 0, 0.42)
        t.addChildNode(coreN)
        t.runAction(.repeatForever(.sequence([
            .scale(to: 1.25, duration: 0.06), .scale(to: 0.82, duration: 0.05), .scale(to: 1.05, duration: 0.05),
        ])))
        return t
    }

    /// A distinct glowing 3D pickup per power-up kind, on a spinning halo ring so it
    /// reads as collectible (weapon = chevron, shield = orb+bubble, bomb = spiked sphere,
    /// life = plus, score = coin, fullHealth = ringed plus, fullShield = double bubble,
    /// recharge = lightning bolt).
    static func powerup(_ kind: PowerupKind) -> SCNNode {
        let c = kind.color
        let root = SCNNode()
        let halo = SCNTorus(ringRadius: 0.55, pipeRadius: 0.05)
        halo.firstMaterial = additive(c, 1.5)
        let hn = SCNNode(geometry: halo); hn.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        root.addChildNode(hn)

        let spin = SCNNode()
        root.addChildNode(spin)
        func add(_ g: SCNGeometry, _ pos: SCNVector3 = SCNVector3Zero, _ e: SCNVector3 = SCNVector3Zero, _ mat: SCNMaterial? = nil) {
            g.firstMaterial = mat ?? Synth.neon(c)
            let n = SCNNode(geometry: g); n.position = pos; n.eulerAngles = e
            spin.addChildNode(n)
        }
        switch kind {
        case .weapon:                                   // forward chevron / missile
            add(SCNCone(topRadius: 0, bottomRadius: 0.26, height: 0.62), SCNVector3(0, 0, -0.1), SCNVector3(-Float.pi / 2, 0, 0))
            add(SCNBox(width: 0.5, height: 0.08, length: 0.16, chamferRadius: 0.03), SCNVector3(0, 0, 0.18))
        case .shield:                                   // orb in a bubble ring
            add(SCNSphere(radius: 0.26))
            add(SCNTorus(ringRadius: 0.42, pipeRadius: 0.03), .init(), SCNVector3(0, 0, Float.pi / 2), additive(c, 1.2))
        case .bomb:                                     // spiked sphere
            add(SCNSphere(radius: 0.28))
            for i in 0..<4 {
                let a = Float(i) / 4 * 2 * Float.pi
                add(SCNCone(topRadius: 0, bottomRadius: 0.07, height: 0.3),
                    SCNVector3(cos(a) * 0.34, 0, sin(a) * 0.34), SCNVector3(Float.pi / 2, 0, a))
            }
        case .life:                                     // plus sign
            add(SCNBox(width: 0.5, height: 0.16, length: 0.16, chamferRadius: 0.04))
            add(SCNBox(width: 0.16, height: 0.5, length: 0.16, chamferRadius: 0.04))
        case .score:                                    // coin
            add(SCNCylinder(radius: 0.3, height: 0.07), .init(), SCNVector3(0, 0, Float.pi / 2))
        case .fullHealth:                               // big plus inside a ring
            add(SCNBox(width: 0.56, height: 0.18, length: 0.18, chamferRadius: 0.05))
            add(SCNBox(width: 0.18, height: 0.56, length: 0.18, chamferRadius: 0.05))
            add(SCNTorus(ringRadius: 0.46, pipeRadius: 0.04), .init(), SCNVector3(0, 0, Float.pi / 2), additive(c, 1.3))
        case .fullShield:                               // orb in a double bubble
            add(SCNSphere(radius: 0.28))
            add(SCNTorus(ringRadius: 0.46, pipeRadius: 0.035), .init(), SCNVector3(0, 0, Float.pi / 2), additive(c, 1.2))
            add(SCNTorus(ringRadius: 0.46, pipeRadius: 0.035), .init(), SCNVector3(Float.pi / 3, 0, Float.pi / 2), additive(c, 1.2))
        case .recharge:                                 // lightning slashes
            add(SCNBox(width: 0.14, height: 0.44, length: 0.12, chamferRadius: 0.03),
                SCNVector3(0.11, 0.17, 0), SCNVector3(0, 0, 0.55))
            add(SCNBox(width: 0.14, height: 0.44, length: 0.12, chamferRadius: 0.03),
                SCNVector3(-0.11, -0.17, 0), SCNVector3(0, 0, 0.55))
            add(SCNBox(width: 0.3, height: 0.1, length: 0.12, chamferRadius: 0.03))
        }
        spin.runAction(.repeatForever(.rotateBy(x: 0.3, y: 1, z: 0, duration: 1.6)))
        return root
    }

    /// A small billboarded hit-meter that floats above an enemy. Returns (bar, fill);
    /// the engine positions the bar and scales the fill by remaining HP.
    static func enemyBar() -> (SCNNode, SCNNode) {
        let bar = SCNNode()
        bar.constraints = [SCNBillboardConstraint()]
        bar.renderingOrder = 12   // draw over the ships
        let track = SCNPlane(width: 1.0, height: 0.16)
        let tm = SCNMaterial(); tm.lightingModel = .constant
        tm.diffuse.contents = UIColor(white: 0, alpha: 0.55); tm.writesToDepthBuffer = false
        track.firstMaterial = tm
        let tn = SCNNode(geometry: track); bar.addChildNode(tn)
        let fill = SCNPlane(width: 1.0, height: 0.12)
        fill.firstMaterial = additive(Synth.lime, 1.6)
        let fn = SCNNode(geometry: fill); fn.position = SCNVector3(0, 0, 0.02); bar.addChildNode(fn)
        return (bar, fn)
    }

    /// A flat additive disc that sits on the floor under an entity — the "shadow" the
    /// player lines up to aim. Caller positions / scales / sets opacity.
    static func groundMarker(_ color: UIColor) -> SCNNode {
        let p = SCNPlane(width: 1, height: 1)
        let m = additive(color, 1.2)
        m.emission.contents = glow
        m.multiply.contents = color
        p.firstMaterial = m
        let n = SCNNode(geometry: p)
        n.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)   // lie flat on the floor
        n.renderingOrder = -4   // above the grid/clouds, below entities
        return n
    }

    // MARK: plasma shader (orb-style fbm domain warp)

    /// `.surface` modifier: turbulent fbm fireball, white-hot core → magenta → cyan,
    /// animated by `scn_frame.time`, with a radial falloff. Written as MSL so it bloom-
    /// pops; if it fails to compile SceneKit ignores it and the plasma texture shows.
    static let plasmaSurfaceModifier = """
    float gfx_hash(float2 p){ p = fract(p*float2(123.34,345.45)); p += dot(p,p+34.345); return fract(p.x*p.y); }
    float gfx_noise(float2 p){
        float2 i = floor(p), f = fract(p);
        float2 u = f*f*(3.0-2.0*f);
        float a = gfx_hash(i), b = gfx_hash(i+float2(1.0,0.0));
        float c = gfx_hash(i+float2(0.0,1.0)), d = gfx_hash(i+float2(1.0,1.0));
        return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
    }
    float gfx_fbm(float2 p){ float v=0.0, a=0.5; for(int i=0;i<5;i++){ v+=a*gfx_noise(p); p*=2.0; a*=0.5; } return v; }
    #pragma body
    float2 uv = _surface.diffuseTexcoord * 2.0 - 1.0;
    float r = length(uv);
    float t = scn_frame.time;
    float2 q = uv * 2.2;
    float2 warp = float2(gfx_fbm(q + t*0.7), gfx_fbm(q - t*0.6 + 4.1));
    float d = gfx_fbm(q + warp*1.9 + float2(0.0, -t*1.2));
    d = pow(clamp(d, 0.0, 1.0), 1.5);
    float core = smoothstep(1.0, 0.0, r);
    float fire = d * core;
    float3 col = mix(float3(1.0,0.96,0.75), float3(1.0,0.55,0.10), smoothstep(0.0,0.40,1.0-fire)); // white→orange
    col = mix(col, float3(0.95,0.13,0.16), smoothstep(0.45,1.0, r));                                // →red edge
    col = mix(col, float3(1.0,0.20,0.62), smoothstep(0.82,1.0, r) * 0.5);                           // magenta licks
    col *= fire * 2.6;
    _surface.emission = float4(col, 1.0);
    _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
    """

    // MARK: neon cloud floor

    /// A glowing neon-cloud layer that sits *below* the glass grid: fbm clouds drifting
    /// toward the camera, magenta↔cyan, animated by `scn_frame.time`. It blooms up
    /// through the transparent grid for the "neon cloud under glass" look.
    static func cloudFloor(width: CGFloat, length: CGFloat) -> SCNNode {
        let plane = SCNPlane(width: width, height: length)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.black
        m.emission.contents = UIColor.black   // shader writes emission; black = safe fallback
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        m.shaderModifiers = [.surface: cloudSurfaceModifier]
        plane.firstMaterial = m
        let n = SCNNode(geometry: plane)
        n.renderingOrder = -8
        return n
    }

    static let cloudSurfaceModifier = """
    float gcl_hash(float2 p){ p = fract(p*float2(123.34,345.45)); p += dot(p,p+34.345); return fract(p.x*p.y); }
    float gcl_noise(float2 p){
        float2 i = floor(p), f = fract(p);
        float2 u = f*f*(3.0-2.0*f);
        float a = gcl_hash(i), b = gcl_hash(i+float2(1.0,0.0));
        float c = gcl_hash(i+float2(0.0,1.0)), d = gcl_hash(i+float2(1.0,1.0));
        return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
    }
    float gcl_fbm(float2 p){ float v=0.0, a=0.5; for(int i=0;i<5;i++){ v+=a*gcl_noise(p); p*=2.0; a*=0.5; } return v; }
    #pragma body
    float2 uv = _surface.diffuseTexcoord;
    float t = scn_frame.time * 0.06;
    float2 p = uv * float2(5.0, 13.0);
    p.y -= t * 3.0;
    float2 warp = float2(gcl_fbm(p + t), gcl_fbm(p*1.3 - t + 7.0));
    float n = gcl_fbm(p + warp*1.7);
    n = pow(clamp(n, 0.0, 1.0), 1.8);
    float mx = gcl_fbm(p*0.6 + 13.0 + t*0.5);
    float3 col = mix(float3(1.0,0.18,0.72), float3(0.28,0.90,1.0), mx);
    float edge = smoothstep(0.0, 0.3, uv.y) * smoothstep(1.0, 0.55, uv.y);
    col *= n * edge * 2.0;
    _surface.emission = float4(col, 1.0);
    _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
    """

    // MARK: procedural texture fallbacks

    private static func proceduralPlasma() -> UIImage {
        let s: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor.black.cgColor); c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            let space = CGColorSpaceCreateDeviceRGB()
            let center = CGPoint(x: s/2, y: s/2)
            let colors = [UIColor.white.cgColor,
                          Synth.magenta.cgColor,
                          Synth.cyan.withAlphaComponent(0.6).cgColor,
                          UIColor.black.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.35, 0.7, 1]) {
                c.drawRadialGradient(g, startCenter: center, startRadius: 0,
                                     endCenter: center, endRadius: s/2, options: [])
            }
        }
    }

    private static func proceduralHull() -> UIImage {
        let s: CGFloat = 256
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 0.07, green: 0.06, blue: 0.12, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: s, height: s))
            // Panel seams.
            c.setStrokeColor(UIColor(white: 1, alpha: 0.06).cgColor); c.setLineWidth(1)
            for i in stride(from: 0, through: s, by: 42) {
                c.move(to: CGPoint(x: i, y: 0)); c.addLine(to: CGPoint(x: i, y: s))
                c.move(to: CGPoint(x: 0, y: i)); c.addLine(to: CGPoint(x: s, y: i))
            }
            c.strokePath()
            // Neon trim strips.
            for (rect, col) in [(CGRect(x: 18, y: 30, width: 220, height: 5), Synth.cyan),
                                (CGRect(x: 40, y: 150, width: 5, height: 90), Synth.magenta),
                                (CGRect(x: 120, y: 90, width: 110, height: 4), Synth.magenta)] {
                c.setFillColor(col.withAlphaComponent(0.85).cgColor); c.fill(rect)
            }
            // Rivets.
            c.setFillColor(UIColor(white: 1, alpha: 0.12).cgColor)
            for x in stride(from: 12, through: s-12, by: 42) {
                for y in stride(from: 12, through: s-12, by: 42) {
                    c.fillEllipse(in: CGRect(x: x-1.5, y: y-1.5, width: 3, height: 3))
                }
            }
        }
    }
}
