import SceneKit
import UIKit

// The native space-shooter engine: owns the SCNScene (camera, lights, fog, biome
// background) and drives all gameplay from `renderer(_:updateAtTime:)` — spawning,
// AI, weapons, collisions, scoring, lives, and level/biome progression. Summary stats
// are published to the observable `GameModel` (on the main thread) for the SwiftUI HUD.
//
// World: +X right, +Y screen-up, −Z forward (into the distance / top of screen). The
// player flies on the X/Y screen-plane near z≈0; enemies spawn at far −Z and advance
// toward +Z. Player bullets travel −Z; enemy fire travels toward the player.

enum PowerupKind: CaseIterable {
    case weapon, shield, bomb, life, score
    // Post-boss respite rewards — never random drops (see `dropPool`); they spawn as a
    // reward line during the lull after a boss so the next level starts powered up.
    case fullHealth, fullShield, recharge
    /// The random-drop pool for enemy kills (the respite rewards are excluded).
    static let dropPool: [PowerupKind] = [.weapon, .shield, .bomb, .life, .score]
    var color: UIColor {
        switch self {
        case .weapon:     return Synth.cyan
        case .shield:     return Synth.amber
        case .bomb:       return Synth.magenta
        case .life:       return Synth.lime
        case .score:      return Synth.white
        case .fullHealth: return Synth.red
        case .fullShield: return Synth.aqua
        case .recharge:   return Synth.violet
        }
    }
}

private final class Enemy {
    let node: SCNNode
    let spec: EnemySpec
    var hp: Int
    let maxHp: Int
    var fireTimer: Double
    var age: Double = 0
    var baseX: Float
    let isBoss: Bool
    var shadow: SCNNode?    // ground alignment marker
    var hpBar: SCNNode?     // floating hit meter above the head (non-boss)
    var hpFill: SCNNode?
    var orbs: [SCNNode] = []     // boss weak-point hitboxes — the only damageable spots
    var evadeOffset: Float = 0   // lateral dodge layered on top of the behaviour path
    var flare: Double = 0        // brief HP-bar / orb flash countdown after taking a hit
    init(node: SCNNode, spec: EnemySpec, hp: Int, baseX: Float, isBoss: Bool) {
        self.node = node; self.spec = spec; self.hp = hp; self.maxHp = hp
        self.baseX = baseX; self.isBoss = isBoss
        self.fireTimer = spec.fireRate > 0 ? spec.fireRate : .greatestFiniteMagnitude
    }
}

private struct Bullet {
    let node: SCNNode; var vel: SCNVector3; var life: Double
    var pierce = false   // beam: passes through enemies, hitting each only once
    var homing = false   // rocket: steers toward the nearest enemy + area damage
    var dmg = 1
    var hitIDs = Set<ObjectIdentifier>()   // enemies a pierce bolt has already damaged
}
private final class Pickup { let node: SCNNode; let kind: PowerupKind; var vel: SCNVector3
    init(node: SCNNode, kind: PowerupKind, vel: SCNVector3) { self.node = node; self.kind = kind; self.vel = vel } }
/// A thrown bomb that flies forward (−Z) and detonates in a wide horizontal blast on
/// the first ship it reaches (or when its fuse runs out).
private struct BombProj { let node: SCNNode; var vel: SCNVector3; var life: Double }

/// A bolt-on weapon type for a side mount. Pickups stack these around the ship instead
/// of replacing the main gun (the main twin-PULSE always fires).
private enum MountWeapon: Int, CaseIterable {
    case laser, spread, seeker, rail, plasma, beam
    var color: UIColor {
        switch self {
        case .laser:  return Synth.lime
        case .spread: return Synth.cyan
        case .seeker: return Synth.orange
        case .rail:   return Synth.aqua
        case .plasma: return Synth.violet
        case .beam:   return Synth.magenta
        }
    }
    var rate: Double {   // seconds between this mount's shots — slower = heavier hit
        switch self {
        case .laser:  return 0.18
        case .spread: return 0.5
        case .seeker: return 0.75
        case .rail:   return 0.35
        case .plasma: return 0.95
        case .beam:   return 0.22
        }
    }
    var spins: Bool { self == .seeker }      // seekers ride the spinning ring; guns are fixed
    var isMissile: Bool { self == .seeker }
}
/// One attached weapon pod: its node (child of the ship or the orbit ring) + its own
/// fire cadence.
private struct Mount { let node: SCNNode; let weapon: MountWeapon; var fireTimer: Double }

final class SpaceShooterEngine: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let model: GameModel
    var onGameOver: () -> Void = {}

    // World bounds.
    private let bx: Float = 9, yMin: Float = -3, yMax: Float = 6
    private let spawnZ: Float = -64, despawnZ: Float = 22
    // New-run loadout; the respite fullHealth/recharge rewards also refill to these.
    private let startLives = 3, startBombs = 3
    private let playerRadius: Float = 0.9
    private let bossHoldZ: Float = -16
    /// Everything lives on one horizontal plane — the player only strafes left/right,
    /// so lining up an enemy is purely a left/right job (much more playable).
    private let planeY: Float = 1.0

    // Scene nodes.
    private let cameraNode = SCNNode()
    private let worldRoot = SCNNode()
    private let gridNode = SCNNode()
    private var player = SCNNode()
    private var playerShadow = SCNNode()
    private var frontThrusters: [SCNNode] = []   // forward-facing braking jets (fire when reversing)
    private let playerHealth = SCNNode()         // neon-green life pips floating over the ship
    private var healthPips: [SCNNode] = []

    // Ground-shadow alignment + haptics.
    private var floorY: Float { yMin - 1.1 }
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var wasAligned = false
    private var lastHaptic: Double = 0

    // Entities.
    private var enemies: [Enemy] = []
    private var pBullets: [Bullet] = []
    private var eBullets: [Bullet] = []
    private var pickups: [Pickup] = []
    private var bombProjectiles: [BombProj] = []
    private var deathDebris: [SCNNode] = []   // floating ship fragments after the run ends
    private var playerScaleNow: Float = 1     // shrinks as the ship dives forward (perspective dive)
    private var hurtFlare: Double = 0         // brief life-pip flash when the player is hit
    private var mounts: [Mount] = []          // bolt-on side weapons (max 6, FIFO)
    private var orbitRing: SCNNode?           // spinning ring — host for orbiting (seeker) mounts
    private var pairsAdded = 0                // total pairs ever added (drives weapon-type cycling)

    // Run state.
    private var shipId = 0
    private var score = 0, lives = 3, level = 1, biome = 0, weaponLevel = 1, bombs = 2
    private var best = GamePersistence.loadBest()
    private var shieldTime: Double = 0
    private var invuln: Double = 0
    private var bossActive = false
    private var bossSpawnedThisLevel = false
    private var bossRef: Enemy?
    // Engine-side copy of the boss bar value; reaches `model` only via publish() (main
    // thread). Writing @Published from the render thread deadlocks SwiftUI intermittently.
    private var bossHealthValue: Double = -1
    // OVERDRIVE super-beam.
    private var superActive = false
    private var superRequested = false
    private var superTime: Double = 0
    private var superCharge: Double = 1
    private var superBeamNode: SCNNode?
    private var superDual = false   // when the shield is up, OVERDRIVE splits to two side beams
    private let superDuration: Double = 3, superRecharge: Double = 14
    // Shield-wall barrier (4s invuln + X-wing S-foil mount spread).
    private var barrierTime: Double = 0
    private var barrierCharge: Double = 1
    private var barrierRequested = false
    private var barrierNode: SCNNode?
    private var mountSpread: Float = 1
    private let barrierDuration: Double = 4, barrierRecharge: Double = 12
    /// Occasional alternate explosion tints — every now and then a kill bursts off-accent.
    private let burstColors: [UIColor] = [Synth.magenta, Synth.cyan, Synth.lime, Synth.amber,
                                          Synth.orange, Synth.violet, Synth.red, Synth.aqua]

    // Timing.
    private var lastTime: TimeInterval = 0
    private var levelTime: Double = 0
    private var spawnTimer: Double = 0
    private var fireTimer: Double = 0
    private var gridScroll: Float = 0

    // Player target (driven by touch) — moves on the X/Z ground plane (no up/down).
    private var targetX: Float = 0
    private var targetY: Float = 1
    private var targetZ: Float = 0
    private let zMin: Float = -44, zMax: Float = 7   // forward / back travel — dive deep to grab pickups

    init(model: GameModel) {
        self.model = model
        super.init()
        setupScene()
    }

    // MARK: scene

    private func setupScene() {
        scene.rootNode.addChildNode(worldRoot)

        let cam = SCNCamera()
        cam.fieldOfView = 55
        cam.zNear = 0.5; cam.zFar = 200
        // HDR + bloom: makes every emissive neon (bolts, engines, trim, grid, plasma)
        // glow like the Bridge orb — the core of the "heavy shader" look.
        cam.wantsHDR = true
        cam.bloomIntensity = 1.5
        cam.bloomThreshold = 0.55
        cam.bloomBlurRadius = 12
        cam.wantsExposureAdaptation = false
        cam.exposureOffset = -0.4
        cam.motionBlurIntensity = 0.3
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 8.5, 18)
        let target = SCNNode(); target.position = SCNVector3(0, 1.5, -8)
        scene.rootNode.addChildNode(target)
        cameraNode.constraints = [SCNLookAtConstraint(target: target)]
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient
        ambient.light!.color = UIColor(white: 0.20, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional
        key.light!.color = Synth.magenta; key.light!.intensity = 900
        key.eulerAngles = SCNVector3(-0.6, 0.7, 0)
        scene.rootNode.addChildNode(key)

        let rim = SCNNode(); rim.light = SCNLight(); rim.light!.type = .directional
        rim.light!.color = Synth.cyan; rim.light!.intensity = 700
        rim.eulerAngles = SCNVector3(0.4, -1.0, 0)
        scene.rootNode.addChildNode(rim)

        // Neon cloud layer — glowing fbm clouds that bloom up through the glass grid.
        let cloud = GameFX.cloudFloor(width: 140, length: 300)
        cloud.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        cloud.position = SCNVector3(0, yMin - 3.2, -80)
        scene.rootNode.addChildNode(cloud)

        // Glass neon grid floor: additive lines (no solid base) over the clouds.
        let floor = SCNPlane(width: 80, height: 200)
        let gm = SCNMaterial(); gm.lightingModel = .constant
        gm.diffuse.contents = UIColor.black
        gm.emission.wrapS = .repeat; gm.emission.wrapT = .repeat
        gm.emission.contents = TextureGen.grid(line: Synth.magenta)
        gm.emission.intensity = 1.3
        gm.blendMode = .add
        gm.writesToDepthBuffer = false
        floor.firstMaterial = gm
        gridNode.geometry = floor
        gridNode.renderingOrder = -6
        gridNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        gridNode.position = SCNVector3(0, yMin - 1.2, -60)
        scene.rootNode.addChildNode(gridNode)

        // Parallax starfield drifting toward the camera.
        let stars = SCNParticleSystem()
        stars.particleImage = TextureGen.dot(.white, size: 16)
        stars.birthRate = 60
        stars.particleLifeSpan = 5
        stars.particleLifeSpanVariation = 2
        stars.emitterShape = SCNBox(width: 90, height: 60, length: 1, chamferRadius: 0)
        stars.birthLocation = .volume
        stars.emittingDirection = SCNVector3(0, 0, 1)
        stars.spreadingAngle = 4
        stars.particleVelocity = 24
        stars.particleVelocityVariation = 18
        stars.particleSize = 0.12
        stars.particleSizeVariation = 0.12
        stars.particleColor = Synth.aqua
        stars.blendMode = .additive
        stars.isLightingEnabled = false
        let starNode = SCNNode()
        starNode.position = SCNVector3(0, 2, spawnZ)
        starNode.addParticleSystem(stars)
        scene.rootNode.addChildNode(starNode)

        applyBiome(0)
    }

    private func applyBiome(_ index: Int) {
        let b = Biome.at(index)
        let n = ((index % Biome.all.count) + Biome.all.count) % Biome.all.count
        scene.background.contents = GameArt.bundled("sx-bg\(n + 1)")    // Higgsfield biome backdrop
            ?? TextureGen.nebula(top: b.bgTop, bottom: b.bgBottom, glow: b.sun)
        scene.fogColor = b.fog
        scene.fogStartDistance = 26
        scene.fogEndDistance = 78
        scene.fogDensityExponent = 1.4
        if let gm = gridNode.geometry?.firstMaterial {
            // Floor neon colour rotates per level so every level looks distinct.
            let hue = CGFloat((0.84 + Double(level) * 0.137).truncatingRemainder(dividingBy: 1.0))
            let gridCol = UIColor(hue: hue, saturation: 0.85, brightness: 1.0, alpha: 1)
            gm.emission.contents = TextureGen.grid(line: gridCol)
            gm.emission.wrapS = .repeat; gm.emission.wrapT = .repeat
        }
    }

    // MARK: lifecycle

    func startNew(shipId: Int) {
        clearEntities()
        self.shipId = shipId
        score = 0; lives = startLives; level = 1; biome = 0; weaponLevel = 1; bombs = startBombs
        shieldTime = 2; invuln = 2.0; levelTime = 0; spawnTimer = 0.8; fireTimer = 0
        bossActive = false; bossSpawnedThisLevel = false; bossRef = nil; bossHealthValue = -1
        superActive = false; superRequested = false; superTime = 0; superCharge = 1; superDual = false
        superBeamNode?.removeFromParentNode(); superBeamNode = nil
        barrierTime = 0; barrierCharge = 1; barrierRequested = false
        barrierNode?.removeFromParentNode(); barrierNode = nil; mountSpread = 1
        targetX = 0; targetY = planeY; targetZ = 0
        applyBiome(0)
        GameMusic.shared.setLevel(1)
        GameMusic.shared.setBossMode(false)
        buildPlayer()
        model.status = .playing
        showBanner("LEVEL 1")
        publish(force: true)
    }

    func restore(_ s: GameSnapshot) {
        clearEntities()
        shipId = s.playerShipId
        score = s.score; lives = s.lives; level = s.level; biome = s.biome
        weaponLevel = s.weaponLevel; bombs = s.bombs; best = max(best, s.best)
        shieldTime = 0; invuln = 1.0
        levelTime = s.levelTime; spawnTimer = 0; fireTimer = 0
        bossActive = false; bossSpawnedThisLevel = s.levelTime >= bossTime
        bossRef = nil; bossHealthValue = -1
        superActive = false; superRequested = false; superTime = 0; superCharge = 1; superDual = false
        superBeamNode?.removeFromParentNode(); superBeamNode = nil
        barrierTime = 0; barrierCharge = 1; barrierRequested = false
        barrierNode?.removeFromParentNode(); barrierNode = nil; mountSpread = 1
        targetX = clampf(s.playerX, -bx, bx); targetY = planeY; targetZ = 0
        applyBiome(biome)
        GameMusic.shared.setLevel(level)
        buildPlayer()
        // Rebuild stacked weapon mounts pair-by-pair (forcing each saved type).
        let kinds = (s.mountKinds ?? []).compactMap { MountWeapon(rawValue: $0) }
        for i in stride(from: 0, to: kinds.count, by: 2) { addWeaponPair(kinds[i]) }
        refreshFirepower()
        player.position = SCNVector3(targetX, targetY, 0)
        model.status = .playing
        publish(force: true)
    }

    func snapshot() -> GameSnapshot {
        GameSnapshot(status: model.status == .over ? .over : .playing,
                     score: score, lives: lives, level: level, biome: biome,
                     weaponLevel: weaponLevel, bombs: bombs, best: best, playerShipId: shipId,
                     levelTime: levelTime, playerX: player.position.x, playerY: player.position.y,
                     mountKinds: mounts.map { $0.weapon.rawValue })
    }

    func pause() { if model.status == .playing { model.status = .paused } }
    func resume() { if model.status == .paused { model.status = .playing; lastTime = 0 } }

    private func buildPlayer() {
        player.removeFromParentNode()
        playerShadow.removeFromParentNode()
        let ship = PlayerShip.all[min(shipId, PlayerShip.all.count - 1)]
        player = SCNNode()
        player.addChildNode(ShipKit.playerHull(accent: ship.accent))
        let ring = GameFX.orbitRing(color: ship.accent)
        player.addChildNode(ring)
        orbitRing = ring
        mounts.removeAll(); pairsAdded = 0   // attachments reset with the ship (incl. on death)
        for sx: Float in [-0.55, 0.55] {
            let th = GameFX.thruster()
            th.position = SCNVector3(sx, -0.02, 1.3)   // engine outlets at the tail
            player.addChildNode(th)
        }
        // Forward-facing braking jets near the nose — only fire when reversing.
        frontThrusters = []
        for sx: Float in [-0.4, 0.4] {
            let ft = GameFX.thruster(color: Synth.teal)
            ft.eulerAngles = SCNVector3(0, Float.pi, 0)   // flame points forward (−Z)
            ft.scale = SCNVector3(0.5, 0.5, 0.55)
            ft.position = SCNVector3(sx, -0.02, -1.2)
            ft.opacity = 0
            player.addChildNode(ft)
            frontThrusters.append(ft)
        }
        player.position = SCNVector3(targetX, targetY, 0)
        playerScaleNow = 1; hurtFlare = 0
        worldRoot.addChildNode(player)
        haptic.prepare()
        playerShadow = GameFX.groundMarker(Synth.teal)
        worldRoot.addChildNode(playerShadow)

        // Neon-green health pips floating over the ship (one per life).
        playerHealth.isHidden = false
        playerHealth.childNodes.forEach { $0.removeFromParentNode() }
        playerHealth.constraints = [SCNBillboardConstraint()]
        playerHealth.renderingOrder = 14
        healthPips = []
        for _ in 0..<8 {
            let p = SCNPlane(width: 0.34, height: 0.16); p.cornerRadius = 0.06
            p.firstMaterial = GameFX.additive(Synth.neonGreen, 1.9)
            let n = SCNNode(geometry: p)
            playerHealth.addChildNode(n)
            healthPips.append(n)
        }
        worldRoot.addChildNode(playerHealth)
    }

    private func clearEntities() {
        for e in enemies { e.node.removeFromParentNode(); e.shadow?.removeFromParentNode(); e.hpBar?.removeFromParentNode() }
        for b in pBullets { b.node.removeFromParentNode() }
        for b in eBullets { b.node.removeFromParentNode() }
        for b in bombProjectiles { b.node.removeFromParentNode() }
        for p in pickups { p.node.removeFromParentNode() }
        for d in deathDebris { d.removeFromParentNode() }
        playerShadow.removeFromParentNode()
        playerHealth.removeFromParentNode()
        enemies.removeAll(); pBullets.removeAll(); eBullets.removeAll(); pickups.removeAll()
        bombProjectiles.removeAll(); deathDebris.removeAll()
        mounts.removeAll(); pairsAdded = 0; orbitRing = nil
    }

    // MARK: control surface (from the view)

    /// Move the player on the ground plane — left/right (X) and forward/back (Z); drag
    /// up flies forward (−Z). No up/down.
    func dragBy(dx: Float, dy: Float) {
        targetX = clampf(targetX + dx * 0.05, -bx, bx)
        targetZ = clampf(targetZ + dy * 0.05, zMin, zMax)
    }

    /// Lob a bomb straight ahead of the ship. It flies forward and detonates on the first
    /// ship it reaches (or when its fuse burns out) — see updateBombs / bombDetonate.
    func useBomb() {
        guard model.status == .playing, bombs > 0 else { return }
        bombs -= 1
        let o = player.position
        let n = GameFX.bombProjectile()
        n.position = o + SCNVector3(0, 0, -1.6)
        worldRoot.addChildNode(n)
        bombProjectiles.append(BombProj(node: n, vel: SCNVector3(0, 0, -48), life: 1.9))
        muzzle(Synth.magenta, at: o, scale: 1.0)
        GameMusic.shared.sfxShoot(3)
        publish()
    }

    /// Advance live bombs; detonate on contact with a ship or when the fuse expires.
    private func updateBombs(_ dt: Double) {
        let dtf = Float(dt)
        var alive: [BombProj] = []
        for var b in bombProjectiles {
            b.node.position = b.node.position + b.vel * dtf
            b.life -= dt
            let pos = b.node.position
            // First ship in the bomb's path.
            let hit = enemies.first { e in
                abs(pos.x - e.node.position.x) < e.spec.radius + 0.7
                    && abs(pos.z - e.node.position.z) < e.spec.radius + 0.9
            }
            if hit != nil || b.life <= 0 || pos.z < spawnZ - 2 {
                b.node.removeFromParentNode()
                bombDetonate(at: pos)
            } else {
                alive.append(b)
            }
        }
        bombProjectiles = alive
    }

    /// A wide horizontal blast + rising mushroom cloud that wipes the row it goes off in.
    private func bombDetonate(at pos: SCNVector3) {
        worldRoot.addChildNode(GameFX.horizontalBlast(width: bx * 2.2).positioned(pos))
        worldRoot.addChildNode(GameFX.mushroomCloud(scale: 4.5).positioned(pos))
        GameMusic.shared.sfxBoom()
        DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
        // Sweep everything within the horizontal band the bomb went off in.
        let zBand: Float = 4.5
        for e in enemies where abs(e.node.position.z - pos.z) < zBand + e.spec.radius {
            damage(e, e.isBoss ? 14 : 999)
        }
        // Vaporise enemy fire crossing the blast row.
        eBullets = eBullets.filter { b in
            if abs(b.node.position.z - pos.z) < zBand { b.node.removeFromParentNode(); return false }
            return true
        }
    }

    /// Fire OVERDRIVE — handled on the render thread next frame (see updateSuper).
    func activateSuper() { superRequested = true }

    /// Raise the shield wall — handled on the render thread next frame (updateBarrier).
    func activateBarrier() { barrierRequested = true }

    // MARK: per-frame update

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if lastTime == 0 { lastTime = time; return }
        let dt = min(0.05, time - lastTime)
        lastTime = time
        // Grid scroll always animates (alive backdrop even when paused/over).
        gridScroll += Float(dt) * 6
        if let gm = gridNode.geometry?.firstMaterial {
            let s = SCNMatrix4MakeScale(10, 26, 1)
            gm.diffuse.contentsTransform = SCNMatrix4Mult(s, SCNMatrix4MakeTranslation(0, gridScroll, 0))
            gm.emission.contentsTransform = gm.diffuse.contentsTransform
        }
        guard model.status == .playing else { GameMusic.shared.setThrust(0); return }
        step(dt)
    }

    private func step(_ dt: Double) {
        let dtf = Float(dt)
        levelTime += dt
        if shieldTime > 0 { shieldTime = max(0, shieldTime - dt) }
        if invuln > 0 { invuln = max(0, invuln - dt) }

        // Player follow + bank.
        let p = player.position
        let np = SCNVector3(p.x + (targetX - p.x) * min(1, dtf * 12),
                            planeY,
                            p.z + (targetZ - p.z) * min(1, dtf * 12))
        player.position = np
        // Shrink as the ship dives forward (−Z) so diving deep to grab pickups reads as
        // distance — 1.0 at the near edge, ~0.45 at the far edge.
        let depthT = clampf((np.z - zMax) / (zMin - zMax), 0, 1)
        playerScaleNow = 1 - depthT * 0.55
        let bank = clampf(-(targetX - p.x) * 0.25, -0.5, 0.5)
        player.scale = SCNVector3(playerScaleNow, playerScaleNow, playerScaleNow)
        player.eulerAngles = SCNVector3(0, 0, bank)
        player.opacity = invuln > 0 ? CGFloat(0.4 + 0.6 * abs(sinf(Float(levelTime) * 30))) : 1
        playerShadow.position = SCNVector3(np.x, floorY, np.z)
        playerShadow.scale = SCNVector3(1.3 * playerScaleNow, 1.3 * playerScaleNow, 1.3 * playerScaleNow)
        // Braking jets at the nose fire when reversing (moving back toward the camera).
        let braking: CGFloat = (np.z - p.z) > 0.015 ? 1 : 0
        for ft in frontThrusters { ft.opacity += (braking - ft.opacity) * 0.4 }
        // Thruster whine while pushing forward (−Z): louder the harder you're driving in.
        GameMusic.shared.setThrust(clampf((p.z - targetZ) * 0.6, 0, 1))
        // Health pips above the ship — show one per remaining life, centred. They flare
        // (pop + flash white) for a beat when the player takes a hit.
        if hurtFlare > 0 { hurtFlare = max(0, hurtFlare - dt) }
        let hf = Float(hurtFlare > 0 ? hurtFlare / 0.4 : 0)   // 1 → 0
        let pipScale = playerScaleNow * (1 + hf * 0.6)
        playerHealth.position = SCNVector3(np.x, np.y + 1.7 * playerScaleNow, np.z)
        playerHealth.scale = SCNVector3(pipScale, pipScale, pipScale)
        let shown = max(0, min(lives, healthPips.count))
        for (i, pip) in healthPips.enumerated() {
            pip.isHidden = i >= shown
            if i < shown { pip.position = SCNVector3((Float(i) - Float(shown - 1) / 2) * 0.42, 0, 0) }
            pip.geometry?.firstMaterial?.emission.intensity = 1.9 + CGFloat(hf) * 3.5
        }

        autoFire(dt)
        spawnLogic(dt)
        updateEnemies(dt)
        updateBullets(dt)
        updateBombs(dt)
        updatePickups(dt)
        collisions()
        updateSuper(dt)
        updateBarrier(dt)
        updateAlignment()
        publish()
    }

    /// Shield wall: a holographic steel barrier in front of the ship grants 4s of total
    /// invulnerability; while it's up the weapon mounts swing out to the sides (X-wing
    /// S-foils) so they keep firing past the wall. Recharges over time when idle.
    private func updateBarrier(_ dt: Double) {
        if barrierRequested {
            barrierRequested = false
            if barrierTime <= 0, barrierCharge >= 1 {
                barrierTime = barrierDuration; barrierCharge = 0
                let wall = GameFX.barrierWall(); wall.position = SCNVector3(0, 0.1, -2.2)
                player.addChildNode(wall); barrierNode = wall
                DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            }
        }
        if barrierTime > 0 {
            barrierTime = max(0, barrierTime - dt)
            if barrierTime <= 0 { barrierNode?.removeFromParentNode(); barrierNode = nil }
        } else if barrierCharge < 1 {
            barrierCharge = min(1, barrierCharge + dt / barrierRecharge)
        }
        // S-foil spread: ease the mounts outward while the wall is up, back when it drops.
        let target: Float = barrierTime > 0 ? 1.95 : 1.0
        let prev = mountSpread
        mountSpread += (target - mountSpread) * Float(min(1, dt * 6))
        if !mounts.isEmpty, abs(mountSpread - prev) > 0.0008 { relayoutMounts() }
    }

    /// OVERDRIVE: while active, a beam down the player's column destroys everything it
    /// sweeps over (drag left/right to mow the screen). Recharges over time when idle.
    private func updateSuper(_ dt: Double) {
        if superRequested {
            superRequested = false
            if !superActive, superCharge >= 1 {
                superActive = true; superTime = superDuration; superCharge = 0
                // Shield up → split into two side beams (the wall blocks the centre).
                superDual = barrierTime > 0
                let accent = PlayerShip.all[min(shipId, PlayerShip.all.count - 1)].accent
                let container = SCNNode()
                let offsets: [Float] = superDual ? [-2.4, 2.4] : [0]
                for ox in offsets {
                    let beam = GameFX.superBeam(accent); beam.position = SCNVector3(ox, 0, -1.2)
                    container.addChildNode(beam)
                }
                player.addChildNode(container); superBeamNode = container
                showBanner("OVERDRIVE")
                DispatchQueue.main.async { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
            }
        }
        if superActive {
            superTime -= dt
            let px = player.position.x, pz = player.position.z
            let cols: [Float] = superDual ? [px - 2.4, px + 2.4] : [px]
            let halfW: Float = superDual ? 1.6 : 1.9
            for e in enemies where e.node.position.z < pz + 1
                && cols.contains(where: { abs(e.node.position.x - $0) < halfW }) {
                damage(e, e.isBoss ? 2 : 999)
            }
            eBullets = eBullets.filter { b in
                if b.node.position.z < pz, cols.contains(where: { abs(b.node.position.x - $0) < halfW }) {
                    b.node.removeFromParentNode(); return false
                }
                return true
            }
            if superTime <= 0 { superActive = false; superBeamNode?.removeFromParentNode(); superBeamNode = nil }
        } else if superCharge < 1 {
            superCharge = min(1, superCharge + dt / superRecharge)
        }
    }

    /// A light haptic tick the moment the player lines up (in X) with an enemy ahead —
    /// the ground shadows show the alignment; the buzz confirms a clean shot.
    private func updateAlignment() {
        var aligned = false
        for e in enemies where e.node.position.z < player.position.z + 2
            && abs(e.node.position.x - player.position.x) < 0.9 { aligned = true; break }
        if aligned && !wasAligned && (levelTime - lastHaptic) > 0.12 {
            lastHaptic = levelTime
            DispatchQueue.main.async { [weak self] in
                self?.haptic.impactOccurred(intensity: 0.6); self?.haptic.prepare()
            }
        }
        wasAligned = aligned
        playerShadow.opacity = aligned ? 1.0 : 0.45
    }

    // MARK: spawning & progression

    private let bossTime: Double = 30

    /// 0…1 intensity ramp across levels — gentle opening levels, full heat by ~L9.
    /// Every difficulty knob (spawn rate, enemy speed/HP/fire, engage range) derives
    /// from this so the curve stays in one place.
    private var difficulty: Double { min(1.0, Double(level - 1) / 8.0) }

    private func spawnLogic(_ dt: Double) {
        if bossActive { return }
        if levelTime >= bossTime, !bossSpawnedThisLevel {
            spawnBoss(); return
        }
        spawnTimer -= dt
        if spawnTimer <= 0 {
            spawnEnemy()
            spawnTimer = max(0.4, 1.5 - 1.1 * difficulty)
        }
    }

    private func spawnEnemy() {
        // Bias toward harder types as levels climb.
        let pool = EnemySpec.all
        let cap = min(pool.count, 1 + level)   // L1 starts with just the two easiest types
        let spec = pool[Int.random(in: 0..<cap)]
        let x = Float.random(in: -bx + 1...bx - 1)
        let y = planeY
        let node = spec.make()
        node.eulerAngles = SCNVector3(0, Float.pi, 0)   // face the player (+Z)
        node.position = SCNVector3(x, y, spawnZ)
        if spec.behavior == .drifter || spec.name == "Mite" || spec.name == "Kamak" {
            node.runAction(.repeatForever(.rotateBy(x: 0, y: 0, z: 4, duration: 1)))
        }
        worldRoot.addChildNode(node)
        // Shielding scales with the player's stacked firepower so a maxed loadout doesn't
        // trivialise basic enemies. 0 mounts (main gun only) → unchanged.
        let shield = 1.0 + Double(mounts.count) * 0.3   // 2→1.6× · 4→2.2× · 6→2.8×
        // Basic enemies take ~4–5 hits on L1 ramping to ~7–8 at full heat; genuinely
        // heavy types (e.g. Brute) keep their higher spec HP.
        let base = max(spec.hp, Int.random(in: 4...5) + Int(3 * difficulty))
        let hp = max(1, Int(Double(base) * shield))
        let e = Enemy(node: node, spec: spec, hp: hp, baseX: x, isBoss: false)
        let shadow = GameFX.groundMarker(spec.accent)
        worldRoot.addChildNode(shadow)
        e.shadow = shadow
        let (bar, fill) = GameFX.enemyBar()
        worldRoot.addChildNode(bar)
        e.hpBar = bar; e.hpFill = fill
        enemies.append(e)
    }

    private func spawnBoss() {
        bossSpawnedThisLevel = true; bossActive = true
        let spec = BossSpec.all[(level - 1) % BossSpec.all.count]
        let node = spec.make()
        node.eulerAngles = SCNVector3(0, Float.pi, 0)
        node.position = SCNVector3(0, planeY, spawnZ)
        worldRoot.addChildNode(node)
        // Armour scales with the player's stacked firepower so a maxed loadout doesn't
        // delete the boss instantly. 0 mounts (main gun only) → unchanged.
        let armor = 1.0 + Double(mounts.count) * 0.4   // 2→1.8× · 4→2.6× · 6→3.4×
        let hp = Int(Double(spec.hp) * (1.15 + Double(level - 1) * 0.35) * armor)
        // Reuse EnemySpec shape via a synthetic spec for the boss's stats.
        let es = EnemySpec(name: spec.name, behavior: .turret, hp: hp, speed: spec.speed,
                           fireRate: spec.fireRate, score: 2000 * level, radius: spec.radius, make: spec.make)
        let boss = Enemy(node: node, spec: es, hp: hp, baseX: 0, isBoss: true)
        let shadow = GameFX.groundMarker(Synth.red)
        worldRoot.addChildNode(shadow)
        boss.shadow = shadow
        // Contra-style weak points: glowing orbs are the ONLY damageable hitboxes — core
        // + the two side pods. Hitting the hull does nothing.
        for off in [SCNVector3(0, 0.6, 0), SCNVector3(-2.4, 0, -0.3), SCNVector3(2.4, 0, -0.3)] {
            let orb = GameFX.weakOrb(Synth.amber)
            orb.position = off
            node.addChildNode(orb)
            boss.orbs.append(orb)
        }
        enemies.append(boss); bossRef = boss
        bossHealthValue = 1
        GameMusic.shared.setBossMode(true)   // switch to the minor-key boss theme
        showBanner(spec.name)
    }

    private func bossDefeated() {
        bossActive = false; bossSpawnedThisLevel = false; bossRef = nil
        bossHealthValue = -1
        level += 1; biome = level - 1; levelTime = 0
        spawnTimer = 3.5   // a short lull to breathe before the next wave rolls in
        addWeaponPair()   // reward: another pair of guns
        applyBiome(biome)
        GameMusic.shared.setBossMode(false)
        GameMusic.shared.setLevel(level)
        GameMusic.shared.sfxFanfare()
        showBanner("BOSS DOWN!")
        spawnRespiteRewards()
    }

    /// During the post-boss lull, drift in a reward line — full health, weapons
    /// recharge, full shield — staggered in depth so a single lateral sweep can
    /// collect all three and the next level starts powered up.
    private func spawnRespiteRewards() {
        let rewards: [PowerupKind] = [.fullHealth, .recharge, .fullShield]
        for (i, kind) in rewards.enumerated() {
            let n = GameFX.powerup(kind)
            n.position = SCNVector3((Float(i) - 1) * 3.4, planeY, -26 - Float(i) * 5)
            worldRoot.addChildNode(n)
            pickups.append(Pickup(node: n, kind: kind, vel: SCNVector3(0, 0, 8)))
        }
    }

    // MARK: enemies AI

    private func updateEnemies(_ dt: Double) {
        let dtf = Float(dt)
        let pp = player.position
        let evade01 = Float(mounts.count) / 6   // dodge strength rises with player firepower
        var survivors: [Enemy] = []
        for e in enemies {
            e.age += dt
            var pos = e.node.position
            let spd = e.spec.speed * (1.1 + Float(difficulty) * 0.4)
            if e.isBoss {
                if pos.z < bossHoldZ { pos.z += spd * dtf }
                else {
                    // Hold its distance and sweep slowly + smoothly (no abrupt dodge), so
                    // the player can read its movement and weave through its fire. The
                    // moving weak-orbs still make aiming active.
                    pos.z = bossHoldZ
                    pos.x = sinf(Float(e.age) * 0.6) * (bx - 2.8) + sinf(Float(e.age) * 0.27 + 0.7) * 1.2
                }
            } else {
                switch e.spec.behavior {
                case .dive:
                    pos.z += spd * dtf; pos.x = e.baseX
                case .sineWeave:
                    pos.z += spd * dtf
                    pos.x = e.baseX + sinf(Float(e.age) * 2.2) * 3
                case .strafe:
                    if pos.z < -10 { pos.z += spd * dtf }
                    else { pos.x = e.baseX + sinf(Float(e.age) * 1.8) * 4 }
                case .kamikaze:
                    let dir = (SCNVector3(pp.x, pp.y, pp.z) - pos).normalized
                    pos = pos + dir * (spd * dtf)
                case .turret:
                    pos.z += spd * dtf; pos.x = e.baseX
                case .drifter:
                    pos.z += spd * dtf
                    pos.x = e.baseX + sinf(Float(e.age) * 1.2) * 2.5
                }
                // Evasion: slide out of the player's firing lane (skip kamikazes — they
                // commit to the charge). `pos.x` above is the clean pattern position, so
                // the eased offset doesn't accumulate frame-to-frame.
                if evade01 > 0, e.spec.behavior != .kamikaze, pos.z > -52 {
                    let rel = pos.x - pp.x
                    // Only juke when you're nearly dead-on, and just a small lazy nudge —
                    // enough to make aiming active, not a constant sidestep.
                    let want: Float = abs(rel) < 1.5 ? (rel >= 0 ? 1 : -1) * (0.8 + 1.0 * evade01) : 0
                    e.evadeOffset += (want - e.evadeOffset) * min(1, dtf * 1.5)
                    pos.x = clampf(pos.x + e.evadeOffset, -bx, bx)
                }
            }
            e.node.position = pos

            // Ground shadow: follow on the floor, bigger when lower, bright when X-aligned.
            if let s = e.shadow {
                let alt = clampf((pos.y - yMin) / (yMax - yMin), 0, 1)
                let sz = e.spec.radius * (2.4 - alt * 1.4)
                s.position = SCNVector3(pos.x, floorY, pos.z)
                s.scale = SCNVector3(sz, sz, sz)
                s.opacity = abs(pos.x - pp.x) < 0.9 ? 1.0 : 0.5
            }
            // Hit flare: a quick bright pop on the HP indicator the instant damage lands.
            let flareP = e.flare > 0 ? Float(e.flare / 0.22) : 0   // 1 → 0
            if e.flare > 0 { e.flare = max(0, e.flare - dt) }

            // Floating hit meter above the head (non-boss; boss uses the top bar + orbs).
            if let bar = e.hpBar, let fill = e.hpFill {
                let w = e.spec.radius * 1.5 * (1 + flareP * 0.7)   // bar pops outward on hit
                bar.position = SCNVector3(pos.x, pos.y + e.spec.radius + 0.7, pos.z)
                bar.scale = SCNVector3(w, w, w)
                let frac = max(0, Float(e.hp) / Float(e.maxHp))
                fill.scale = SCNVector3(frac, 1, 1)
                fill.position = SCNVector3(-(1 - frac) * 0.5, 0, 0.02)
                let mat = fill.geometry?.firstMaterial
                mat?.emission.contents = frac > 0.5 ? Synth.lime : (frac > 0.25 ? Synth.amber : Synth.red)
                mat?.emission.intensity = 1.6 + CGFloat(flareP) * 3.2   // flash bright on hit
            }
            // Boss weak-orbs flare bright when struck (they have no floating bar).
            if e.isBoss, flareP > 0 {
                for orb in e.orbs {
                    orb.childNodes.first?.geometry?.firstMaterial?.emission.intensity = 2.4 + CGFloat(flareP) * 4.0
                }
            } else if e.isBoss {
                for orb in e.orbs { orb.childNodes.first?.geometry?.firstMaterial?.emission.intensity = 2.4 }
            }

            // Fire — engage from further out and more often as the difficulty ramps.
            let engageZ = -46 - Float(difficulty) * 8
            if e.spec.fireRate > 0, pos.z > engageZ, pos.z < despawnZ - 2 {
                e.fireTimer -= dt
                if e.fireTimer <= 0 {
                    enemyFire(from: e, toward: pp)
                    e.fireTimer = e.spec.fireRate * (0.9 - 0.45 * difficulty)
                }
            }

            // Despawn behind the camera.
            if pos.z > despawnZ {
                e.node.removeFromParentNode()
                e.shadow?.removeFromParentNode()
                e.hpBar?.removeFromParentNode()
                if e.isBoss { bossActive = false; bossSpawnedThisLevel = true; bossHealthValue = -1 }
                continue
            }
            survivors.append(e)
        }
        enemies = survivors
    }

    // MARK: weapons

    // Main weapon: always the teal twin-PULSE. Extra firepower comes from bolt-on side
    // mounts (see addWeaponPair) which fire on their own cadence — picking up weapons
    // stacks mounts rather than swapping the main gun.
    private func autoFire(_ dt: Double) {
        let ship = PlayerShip.all[min(shipId, PlayerShip.all.count - 1)]
        fireTimer -= dt
        if fireTimer <= 0 {
            fireMain()
            fireTimer = ship.fireRate
        }
        guard !mounts.isEmpty else { return }
        for i in mounts.indices {
            mounts[i].fireTimer -= dt
            if mounts[i].fireTimer <= 0 {
                fireMount(mounts[i])
                mounts[i].fireTimer = mounts[i].weapon.rate
            }
        }
    }

    /// The permanent twin-PULSE from the nose.
    private func fireMain() {
        let o = player.position
        let c = Synth.teal
        GameMusic.shared.sfxShoot(1)
        muzzle(c, at: o, scale: 0.8)
        firePlayer(GameFX.playerBolt(c), at: o + SCNVector3(-0.5, 0, 0), vel: SCNVector3(0, 0, -64), life: 2)
        firePlayer(GameFX.playerBolt(c), at: o + SCNVector3(0.5, 0, 0), vel: SCNVector3(0, 0, -64), life: 2)
    }

    /// Fire one bolt-on mount from its live (animated) world position — so seeker pods
    /// orbiting on the ring launch from wherever they currently are.
    private func fireMount(_ m: Mount) {
        let wp = m.node.presentation.worldPosition
        switch m.weapon {
        case .laser:   // rapid light bolt
            let l = GameFX.playerBolt(Synth.lime); l.scale = SCNVector3(0.7, 0.7, 1.7)
            firePlayer(l, at: wp, vel: SCNVector3(0, 0, -94), life: 1.6)
        case .spread:  // three-pellet fan, light each
            for k: Float in [-1, 0, 1] {
                let b = GameFX.playerBolt(Synth.cyan); b.scale = SCNVector3(0.7, 0.7, 1.2)
                firePlayer(b, at: wp, vel: SCNVector3(k * 16, 0, -72), life: 1.3)
            }
        case .seeker:  // homing missile + area damage
            firePlayer(GameFX.rocket(Synth.orange), at: wp, vel: SCNVector3(0, 0, -44), life: 3, homing: true, dmg: 4)
        case .rail:    // fast thin piercing slug
            let r = GameFX.playerBolt(Synth.aqua); r.scale = SCNVector3(0.5, 0.5, 2.6)
            firePlayer(r, at: wp, vel: SCNVector3(0, 0, -130), life: 1.0, pierce: true, dmg: 3)
        case .plasma:  // slow heavy bolt, big single hit
            let p = GameFX.beamBolt(Synth.violet); p.scale = SCNVector3(1.4, 1.4, 1.1)
            firePlayer(p, at: wp, vel: SCNVector3(0, 0, -40), life: 2.2, dmg: 6)
        case .beam:    // piercing beam
            firePlayer(GameFX.beamBolt(Synth.magenta), at: wp, vel: SCNVector3(0, 0, -82), life: 1.3, pierce: true, dmg: 2)
        }
    }

    /// Attach a pair of weapon pods (one per side). Type cycles laser → spread → seeker →
    /// rail → plasma → beam as the player keeps grabbing weapons. Caps at 6 mounts; the
    /// oldest pair is dropped to make room. Pass `weapon` to force a type (resume).
    private func addWeaponPair(_ weapon: MountWeapon? = nil) {
        let w = weapon ?? MountWeapon.allCases[pairsAdded % MountWeapon.allCases.count]
        pairsAdded += 1
        while mounts.count > 4 {   // drop the oldest pair so adding 2 keeps us ≤ 6
            let old = mounts.removeFirst(); old.node.removeFromParentNode()
        }
        for side: Float in [-1, 1] {
            let pod = GameFX.weaponPod(w.color, missile: w.isMissile)
            (w.spins ? (orbitRing ?? player) : player).addChildNode(pod)
            mounts.append(Mount(node: pod, weapon: w, fireTimer: Double.random(in: 0...w.rate)))
        }
        relayoutMounts()
        refreshFirepower()
    }

    /// Position every mount: fixed guns sit at slots around the ring; seekers ride the
    /// spinning ring (offset per pair so they don't stack).
    private func relayoutMounts() {
        let slots: [SCNVector3] = [SCNVector3(1.7, 0, 0), SCNVector3(1.5, 0, -1.0), SCNVector3(1.5, 0, 1.0)]
        for (i, m) in mounts.enumerated() {
            let pair = i / 2
            let side: Float = (i % 2 == 0) ? -1 : 1
            if m.weapon.spins {
                m.node.position = SCNVector3(side * 1.7 * mountSpread, 0, Float(pair) * 0.5)
            } else {
                let s = slots[min(pair, slots.count - 1)]
                m.node.position = SCNVector3(side * s.x * mountSpread, s.y, s.z)
            }
        }
    }

    /// Mirror the gun count into `weaponLevel` (1 main + mounts) for the HUD.
    private func refreshFirepower() { weaponLevel = min(7, 1 + mounts.count) }

    private func muzzle(_ c: UIColor, at o: SCNVector3, scale: CGFloat) {
        worldRoot.addChildNode(GameFX.flash(c, scale: scale, life: 0.08).positioned(o + SCNVector3(0, 0, -1.3)))
    }

    private func firePlayer(_ n: SCNNode, at: SCNVector3, vel: SCNVector3, life: Double,
                            pierce: Bool = false, homing: Bool = false, dmg: Int = 1) {
        // Bound the live-bullet pool — stacked mounts (esp. long-lived piercing beams +
        // particle-emitting trails) can otherwise pile up and tank the frame rate.
        if pBullets.count >= 80 { let old = pBullets.removeFirst(); old.node.removeFromParentNode() }
        n.position = at
        n.look(at: at + vel)
        worldRoot.addChildNode(n)
        pBullets.append(Bullet(node: n, vel: vel, life: life, pierce: pierce, homing: homing, dmg: dmg))
    }

    /// Nearest enemy position ahead of a point — for rocket homing.
    private func nearestEnemyPos(to p: SCNVector3) -> SCNVector3? {
        var best: SCNVector3?; var bestD = Float.greatestFiniteMagnitude
        for e in enemies where e.node.position.z < p.z + 2 {
            let d = e.node.position.distance(to: p)
            if d < bestD { bestD = d; best = e.node.position }
        }
        return best
    }

    private func enemyFire(from e: Enemy, toward pp: SCNVector3) {
        let speed: Float = e.isBoss ? 22 : 28   // slower boss bolts → more time to weave
        // Bolts take the enemy's accent colour so each type's fire reads differently.
        let boltColor = e.isBoss ? Synth.amber : e.spec.accent
        func shoot(_ dir: SCNVector3, scale: Float = 1) {
            var d = dir; d.y = 0   // keep fire on the play plane so it actually hits
            let n = GameFX.enemyBolt(boltColor)
            let s: Float = e.isBoss ? 1.4 : scale
            if s != 1 { n.scale = SCNVector3(s, s, s) }
            n.position = e.node.position
            n.look(at: e.node.position + d)
            worldRoot.addChildNode(n)
            eBullets.append(Bullet(node: n, vel: d.normalized * speed, life: 4))
        }
        if e.isBoss {
            // Rotate through several weapons during the fight (switch ~every 3.5s) so the
            // attack never feels monotone. The starting weapon is offset per boss, so each
            // boss still opens differently. All patterns leave room to weave.
            let variant = (level - 1) % BossSpec.all.count
            switch (Int(e.age / 3.5) + variant) % 4 {
            case 1:   // wall of bolts with two symmetric moving gaps
                let g = Int(e.age * 1.2) % 4
                for k in [-3, -2, -1, 0, 1, 2, 3] where abs(k) != g && abs(k) != g + 1 {
                    shoot(SCNVector3(Float(k) * 6, 0, 18))
                }
            case 2:   // slow rotating 3-arm spiral (sparse → very dodgeable)
                let base = Float(e.age) * 2.2
                for i in 0..<3 {
                    let a = base + Float(i) * (2 * Float.pi / 3)
                    shoot(SCNVector3(sinf(a) * 16, 0, 18))
                }
            case 3:   // tight aimed burst at the player + two wide flankers
                let toP = pp - e.node.position
                for dxv: Float in [-1.4, 0, 1.4] { shoot(toP + SCNVector3(dxv, 0, 0)) }
                shoot(SCNVector3(-15, 0, 18)); shoot(SCNVector3(15, 0, 18))
            default:  // diverging fan with one wandering open lane
                let lanes = [-3, -2, -1, 0, 1, 2, 3]
                let gap = lanes[Int(e.age * 1.7) % lanes.count]
                for k in lanes where k != gap { shoot(SCNVector3(Float(k) * 6, 0, 20)) }
            }
        } else {
            // Distinct weapon per enemy type.
            let toP = pp - e.node.position
            switch e.spec.behavior {
            case .turret:        // heavy slow aimed shell
                shoot(toP, scale: 1.6)
            case .drifter:       // 3-way spread
                for dxv: Float in [-4, 0, 4] { shoot(toP + SCNVector3(dxv, 0, 0)) }
            case .strafe:        // tight aimed twin burst
                shoot(toP + SCNVector3(-1.2, 0, 0)); shoot(toP + SCNVector3(1.2, 0, 0))
            case .kamikaze:      // fast single aimed (Hunter)
                shoot(toP)
            case .sineWeave:     // straight twin
                shoot(SCNVector3(-0.6, 0, 18)); shoot(SCNVector3(0.6, 0, 18))
            default:             // straight single
                shoot(SCNVector3(0, 0, 18))
            }
            // Muzzle glow at the shooter, tinted to its bolts.
            worldRoot.addChildNode(GameFX.flash(boltColor, scale: 0.55, life: 0.09).positioned(e.node.position))
        }
    }

    private func updateBullets(_ dt: Double) {
        let dtf = Float(dt)
        var pAlive: [Bullet] = []
        for var b in pBullets {
            if b.homing, let tp = nearestEnemyPos(to: b.node.position) {   // rocket steering
                let speed = b.vel.length
                let desired = (tp - b.node.position).normalized * speed
                b.vel = (b.vel + (desired - b.vel) * (dtf * 3.5)).normalized * speed
                b.node.look(at: b.node.position + b.vel)
            }
            b.node.position = b.node.position + b.vel * dtf
            b.life -= dt
            if b.life <= 0 || b.node.position.z < spawnZ - 6 { b.node.removeFromParentNode(); continue }
            pAlive.append(b)
        }
        pBullets = pAlive
        eBullets = eBullets.compactMap { var b = $0
            b.node.position = b.node.position + b.vel * dtf
            b.life -= dt
            if b.life <= 0 || b.node.position.z > despawnZ + 4 { b.node.removeFromParentNode(); return nil }
            return b
        }
    }

    // MARK: pickups

    private func updatePickups(_ dt: Double) {
        let dtf = Float(dt)
        pickups = pickups.filter { p in
            p.node.position = p.node.position + p.vel * dtf
            p.node.eulerAngles.y += dtf * 3
            if p.node.position.z > despawnZ { p.node.removeFromParentNode(); return false }
            return true
        }
    }

    private func maybeDrop(at pos: SCNVector3, boss: Bool) {
        let chance = boss ? 1.0 : 0.2
        guard Double.random(in: 0...1) < chance else { return }
        let kind: PowerupKind = boss ? .weapon
            : PowerupKind.dropPool.randomElement() ?? .score
        let n = GameFX.powerup(kind)
        n.position = pos
        worldRoot.addChildNode(n)
        pickups.append(Pickup(node: n, kind: kind, vel: SCNVector3(0, 0, 8)))
    }

    private func collect(_ p: Pickup) {
        switch p.kind {
        case .weapon:
            addWeaponPair()
            showBanner(mounts.count >= 6 ? "FIREPOWER MAX" : "FIREPOWER ×\(weaponLevel)")
        case .shield: shieldTime = 8; showBanner("SHIELD UP")
        case .bomb:   bombs += 1; showBanner("BOMB +1")
        case .life:   lives += 1; showBanner("1UP")
        case .score:  score += 500; showBanner("+500")
        case .fullHealth:
            lives = max(lives, startLives); showBanner("FULL HEALTH")
        case .fullShield:
            shieldTime = 12; showBanner("FULL SHIELD")
        case .recharge:
            superCharge = 1; barrierCharge = 1; bombs = max(bombs, startBombs)
            showBanner("WEAPONS CHARGED")
        }
        p.node.removeFromParentNode()
        worldRoot.addChildNode(flash(at: p.node.position, color: p.kind.color, scale: 2))
    }

    // MARK: collisions

    private func collisions() {
        let pp = player.position
        // Player bullets → enemies. Hits are based on X-alignment + Z proximity (Y is
        // ignored) so lining up the ground shadows is what lands the shot.
        var liveBullets: [Bullet] = []
        for var b in pBullets {
            var consumed = false
            for e in enemies {
                // Any hit on the boss hull damages it; landing on a glowing weak-point orb
                // does double damage (+ highlight + thonk). Normal enemies: X/Z proximity.
                let hit: Bool
                var orb = false
                if e.isBoss {
                    hit = abs(b.node.position.x - e.node.position.x) < e.spec.radius
                        && abs(b.node.position.z - e.node.position.z) < e.spec.radius + 0.8
                    if hit { orb = e.orbs.contains { orbHit(b.node.position, $0) } }
                } else {
                    hit = abs(b.node.position.x - e.node.position.x) < e.spec.radius + 0.4
                        && abs(b.node.position.z - e.node.position.z) < e.spec.radius + 0.7
                }
                guard hit else { continue }
                let dealt = orb ? b.dmg * 2 : b.dmg
                if b.homing { aoeExplode(at: e.node.position, dmg: dealt); consumed = true; break }
                if b.pierce {
                    // Beam passes through but only damages each enemy once.
                    let id = ObjectIdentifier(e)
                    if b.hitIDs.contains(id) { continue }
                    b.hitIDs.insert(id)
                    damage(e, dealt, orb: orb)
                } else {
                    damage(e, dealt, orb: orb); consumed = true; break
                }
            }
            if consumed { b.node.removeFromParentNode() } else { liveBullets.append(b) }
        }
        pBullets = liveBullets

        // Shield wall up: total invulnerability — the wall vaporises incoming fire in
        // front of the ship and no contact damage lands. Pickups still collect.
        if barrierTime > 0 {
            eBullets = eBullets.filter { b in
                if b.node.position.distance(to: pp) < 2.8 {
                    worldRoot.addChildNode(flash(at: b.node.position, color: Synth.aqua, scale: 0.5))
                    b.node.removeFromParentNode(); return false
                }
                return true
            }
            pickups = pickups.filter { p in
                if p.node.position.distance(to: pp) < 1.5 { collect(p); return false }
                return true
            }
            return
        }

        guard invuln <= 0 else { return }
        let pr = playerRadius * playerScaleNow   // smaller target the deeper the ship dives
        // Enemies → player (body collision).
        for e in enemies where !e.isBoss
            && e.node.position.distance(to: pp) < pr + e.spec.radius * 0.6 {
            damage(e, 999); hitPlayer(); return
        }
        // Enemy bullets → player.
        var liveE: [Bullet] = []
        var struck = false
        for b in eBullets {
            if !struck && b.node.position.distance(to: pp) < pr + 0.3 {
                b.node.removeFromParentNode(); struck = true
            } else { liveE.append(b) }
        }
        eBullets = liveE
        if struck { hitPlayer(); return }
        // Pickups.
        pickups = pickups.filter { p in
            if p.node.position.distance(to: pp) < 1.5 { collect(p); return false }
            return true
        }
    }

    private func damage(_ e: Enemy, _ dmg: Int, orb: Bool = false) {
        e.hp -= dmg
        if e.isBoss { bossHealthValue = max(0, Double(e.hp) / Double(e.maxHp)) }
        if e.hp <= 0 {
            score += e.spec.score
            if score > best { best = score; GamePersistence.saveBest(best) }
            // Usually burst in the enemy's accent, but ~30% of kills pop an alternate tint.
            let burstColor = e.isBoss ? Synth.amber
                : (Double.random(in: 0...1) < 0.3 ? (burstColors.randomElement() ?? e.spec.accent) : e.spec.accent)
            worldRoot.addChildNode(GameFX.explosion(color: burstColor,
                                                    scale: e.isBoss ? 2.8 : 1.2).positioned(e.node.position))
            maybeDrop(at: e.node.position, boss: e.isBoss)
            e.node.removeFromParentNode()
            e.shadow?.removeFromParentNode()
            e.hpBar?.removeFromParentNode()
            enemies.removeAll { $0 === e }
            GameMusic.shared.sfxBoom()
            if e.isBoss { bossDefeated() }
        } else {
            // Boss: only a weak-orb hit lights up the orbs (and 2× damage). Body hits still
            // count but give the duller boom. Normal enemies pop their HP bar on any hit.
            if e.isBoss { e.flare = orb ? 0.35 : 0 } else { e.flare = 0.22 }
            let fc = orb ? Synth.white : e.spec.accent
            worldRoot.addChildNode(flash(at: e.node.position, color: fc, scale: orb ? 0.95 : 0.6))
            if e.isBoss {
                if orb { GameMusic.shared.sfxThonk() } else { GameMusic.shared.sfxBossHit() }
            } else {
                GameMusic.shared.sfxHit()
            }
        }
    }

    /// Whether a bullet (world pos) is touching a boss weak-point orb (world pos).
    private func orbHit(_ p: SCNVector3, _ orb: SCNNode) -> Bool {
        let o = orb.worldPosition
        return abs(p.x - o.x) < 1.0 && abs(p.z - o.z) < 1.2
    }

    /// Rocket area damage — a burst that damages every enemy within radius.
    private func aoeExplode(at pos: SCNVector3, dmg: Int) {
        worldRoot.addChildNode(GameFX.explosion(color: Synth.orange, scale: 1.8).positioned(pos))
        for e in enemies.filter({ $0.node.position.distance(to: pos) < 3.0 }) { damage(e, dmg) }
    }

    private func hitPlayer() {
        hurtFlare = 0.4   // flare the life pips
        if shieldTime > 0 {
            shieldTime = 0; invuln = 1.2
            worldRoot.addChildNode(flash(at: player.position, color: Synth.amber, scale: 3))
            return
        }
        lives -= 1
        invuln = 1.3
        GameMusic.shared.sfxHurt()
        if lives < 0 { gameOver(); return }
        worldRoot.addChildNode(GameFX.explosion(color: Synth.teal, scale: 1.7).positioned(player.position))
    }

    /// Blow the player ship apart into fragments that keep drifting + tumbling behind the
    /// GAME OVER overlay (driven by self-running SCNActions, so they animate even though
    /// the step loop stops once the run ends).
    private func explodePlayerIntoDebris() {
        let pos = player.position
        let accent = PlayerShip.all[min(shipId, PlayerShip.all.count - 1)].accent
        worldRoot.addChildNode(GameFX.explosion(color: Synth.teal, scale: 3.4).positioned(pos))
        worldRoot.addChildNode(flash(at: pos, color: Synth.white, scale: 7))
        for piece in GameFX.shipDebris(accent: accent, scale: playerScaleNow) {
            piece.position = pos + piece.position
            worldRoot.addChildNode(piece)
            deathDebris.append(piece)
        }
        player.isHidden = true
        playerShadow.isHidden = true
        playerHealth.isHidden = true
    }

    private func gameOver() {
        explodePlayerIntoDebris()
        if score > best { best = score; GamePersistence.saveBest(best) }
        GamePersistence.clear()
        publish(force: true)
        DispatchQueue.main.async { [weak self] in
            self?.model.status = .over
            self?.onGameOver()
        }
    }

    // MARK: fx + helpers

    private func flash(at pos: SCNVector3, color: UIColor, scale: CGFloat) -> SCNNode {
        GameFX.flash(color, scale: scale).positioned(pos)
    }

    private func showBanner(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.model.banner = text
        }
        // Auto-clear after a beat.
        let token = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.model.banner == token { self?.model.banner = nil }
        }
    }

    /// Push summary stats to the observable model on the main thread (equality-guarded).
    private func publish(force: Bool = false) {
        let s = score, l = lives, lv = level, bi = biome, wl = weaponLevel, bm = bombs
        let sh = shieldTime, be = best
        let bp = bossActive ? -1.0 : min(levelTime / bossTime, 1.0)
        let bh = bossHealthValue
        let sc = superCharge, sa = superActive
        let bc = barrierCharge, ba = barrierTime > 0
        DispatchQueue.main.async { [weak self] in
            guard let m = self?.model else { return }
            if force || abs(m.bossProgress - bp) > 0.01 { m.bossProgress = bp }
            if force || m.bossHealth != bh { m.bossHealth = bh }
            if force || abs(m.superCharge - sc) > 0.02 { m.superCharge = sc }
            if force || m.superActive != sa { m.superActive = sa }
            if force || abs(m.barrierCharge - bc) > 0.02 { m.barrierCharge = bc }
            if force || m.barrierActive != ba { m.barrierActive = ba }
            if force || m.score != s { m.score = s }
            if force || m.lives != l { m.lives = l }
            if force || m.level != lv { m.level = lv }
            if force || m.biome != bi { m.biome = bi }
            if force || m.weaponLevel != wl { m.weaponLevel = wl }
            if force || m.bombs != bm { m.bombs = bm }
            if force || abs(m.shield - sh) > 0.05 { m.shield = sh }
            if force || m.best != be { m.best = be }
        }
    }
}

private extension SCNNode {
    /// Position this (effect) node and return it, for inline `addChildNode(...)`.
    func positioned(_ p: SCNVector3) -> SCNNode { position = p; return self }
}
