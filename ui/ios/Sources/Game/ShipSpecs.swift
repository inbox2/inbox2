import SceneKit
import UIKit

// Data catalogs: player ships, enemy types, and bosses. Each `make` closure builds a
// fresh node via ShipKit (ships are authored nose-toward−Z; the engine faces enemies
// toward the player). Stats drive HP, movement, fire cadence, and score.

enum AIBehavior: String, Codable {
    case dive        // advance straight down the corridor
    case sineWeave   // sinusoidal drift while advancing
    case strafe      // sweep in, hold, fire, retreat
    case kamikaze    // home toward the player
    case turret      // slow, fires aimed shots
    case drifter     // slow saucer, fires spreads
}

struct PlayerShip {
    let name: String
    let moveSpeed: Float    // how quickly it tracks the touch (units/sec cap)
    let fireRate: Double    // seconds between auto-fire shots
    let accent: UIColor     // neon trim / weapon-ring / bolt colour

    static let all: [PlayerShip] = [
        PlayerShip(name: "Interceptor", moveSpeed: 22, fireRate: 0.16, accent: Synth.teal),
        PlayerShip(name: "Vanguard", moveSpeed: 16, fireRate: 0.13, accent: Synth.aqua),
        PlayerShip(name: "Wraith", moveSpeed: 26, fireRate: 0.18, accent: Synth.violet),
    ]
}

struct EnemySpec {
    let name: String
    let behavior: AIBehavior
    let hp: Int
    let speed: Float       // forward (+Z) units/sec at base difficulty
    let fireRate: Double   // seconds between shots; 0 = never fires
    let score: Int
    let radius: Float      // collision radius
    var accent: UIColor = Synth.magenta   // explosion / hit-spark tint
    let make: () -> SCNNode

    static let all: [EnemySpec] = [
        // Dart — tiny fast wedge interceptor (no fire), magenta-trimmed dark hull.
        EnemySpec(name: "Dart", behavior: .dive, hp: 1, speed: 10, fireRate: 0, score: 50, radius: 1.0) {
            ShipKit.fighter(.init(length: 1.6, width: 1.4, body: Synth.hullDark,
                                  accent: Synth.magenta, glow: 1.3, wing: .delta, engines: 1,
                                  cockpit: false, fin: false, texture: GameFX.enemyHullA))
        },
        // Weaver — wide swept gunship with a holographic targeting emitter.
        EnemySpec(name: "Weaver", behavior: .sineWeave, hp: 2, speed: 8, fireRate: 1.8, score: 90, radius: 1.1) {
            ShipKit.fighter(.init(length: 1.8, width: 2.4, body: Synth.hullDark,
                                  accent: Synth.pink, glow: 1.3, wing: .swept, engines: 2,
                                  cockpit: false, fin: false, holo: true, texture: GameFX.enemyHullA))
        },
        // Stinger — forward-swept assault craft with a dorsal twin cannon.
        EnemySpec(name: "Stinger", behavior: .strafe, hp: 3, speed: 9, fireRate: 1.2, score: 140, radius: 1.1) {
            ShipKit.fighter(.init(length: 2.0, width: 2.2, body: Synth.hullSteel,
                                  accent: Synth.red, glow: 1.2, wing: .forward, engines: 2,
                                  cockpit: true, fin: true, roofCannon: true, texture: GameFX.enemyHullB))
        },
        // Kamak — boxy ramming drone wrapped in spin rings.
        EnemySpec(name: "Kamak", behavior: .kamikaze, hp: 2, speed: 13, fireRate: 0, score: 120, radius: 0.9) {
            ShipKit.drone(accent: Synth.red)
        },
        // Turret — slow heavy-cannon saucer with a holo dome.
        EnemySpec(name: "Turret", behavior: .turret, hp: 4, speed: 4, fireRate: 0.9, score: 160, radius: 1.2) {
            ShipKit.saucer(body: Synth.hullSteel, accent: Synth.purple, glow: 1.3, holo: true, texture: GameFX.enemyHullB)
        },
        // Saucer — drifting spread-shot disc.
        EnemySpec(name: "Saucer", behavior: .drifter, hp: 3, speed: 6, fireRate: 1.5, score: 130, radius: 1.3) {
            ShipKit.saucer(body: Synth.hullDark, accent: Synth.magenta, glow: 1.5, texture: GameFX.enemyHullA)
        },
        // Mite — tiny darting holo-drone.
        EnemySpec(name: "Mite", behavior: .dive, hp: 1, speed: 15, fireRate: 0, score: 60, radius: 0.7) {
            ShipKit.drone(accent: Synth.pink, holo: true)
        },
        // Lancer — long swept striker with a dorsal cannon.
        EnemySpec(name: "Lancer", behavior: .strafe, hp: 3, speed: 11, fireRate: 1.0, score: 150, radius: 1.1) {
            ShipKit.fighter(.init(length: 2.4, width: 2.4, body: Synth.hullDark,
                                  accent: Synth.violet, glow: 1.3, wing: .swept, engines: 2,
                                  cockpit: true, fin: true, roofCannon: true, texture: GameFX.enemyHullC))
        },
        // Hunter — compact delta chaser with a holo emitter.
        EnemySpec(name: "Hunter", behavior: .kamikaze, hp: 3, speed: 12, fireRate: 0.8, score: 180, radius: 1.0) {
            ShipKit.fighter(.init(length: 1.9, width: 1.8, body: Synth.hullSteel,
                                  accent: Synth.red, glow: 1.4, wing: .delta, engines: 2,
                                  cockpit: true, fin: false, holo: true, texture: GameFX.enemyHullB))
        },
        // Brute — huge four-engine battlewagon with a heavy dorsal cannon.
        EnemySpec(name: "Brute", behavior: .dive, hp: 6, speed: 5, fireRate: 0.7, score: 240, radius: 1.6) {
            ShipKit.fighter(.init(length: 3.2, width: 3.6, body: Synth.hullSteel,
                                  accent: Synth.amber, glow: 1.1, wing: .swept, engines: 4,
                                  cockpit: true, fin: true, roofCannon: true, texture: GameFX.enemyHullC))
        },
    ]
}

struct BossSpec {
    let name: String
    let hp: Int
    let speed: Float
    let fireRate: Double
    let radius: Float
    let make: () -> SCNNode

    static let all: [BossSpec] = [
        BossSpec(name: "DREADNOUGHT", hp: 120, speed: 2.5, fireRate: 0.5, radius: 3.6) {
            ShipKit.boss(accent: Synth.magenta, variant: 0)
        },
        BossSpec(name: "THE HIVE", hp: 160, speed: 2.0, fireRate: 0.4, radius: 3.8) {
            ShipKit.boss(accent: Synth.purple, variant: 1)
        },
        BossSpec(name: "REACTOR CORE", hp: 200, speed: 1.8, fireRate: 0.35, radius: 4.0) {
            ShipKit.boss(accent: Synth.cyan, variant: 2)
        },
        BossSpec(name: "OVERLORD", hp: 280, speed: 2.2, fireRate: 0.3, radius: 4.4) {
            ShipKit.boss(accent: Synth.red, variant: 3)
        },
    ]
}
