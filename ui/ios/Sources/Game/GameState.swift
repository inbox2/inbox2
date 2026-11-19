import Foundation
import Combine

// MARK: - Space-shooter game state & resume
//
// The native (SceneKit) Bridge mini-game. `GameModel` is the observable surface the
// SwiftUI HUD reads while the engine writes to it on the main thread. `GameSnapshot`
// is the small Codable blob we persist to UserDefaults so the next open resumes where
// the player left off (live entities are NOT serialized — the scene rebuilds clean and
// the spawner resumes from `levelTime`).

enum GameStatus: String, Codable {
    case idle      // not started / exited
    case playing
    case paused
    case over
}

/// Over-the-top arcade weapon names by tier (1…4). Shared by the engine + HUD.
func weaponName(_ level: Int) -> String {
    switch level {
    case 1:  return "PULSE BLASTER"
    case 2:  return "HYPER LASER"
    case 3:  return "SEEKER ROCKETS"
    default: return "HYPER KILLER BEAM"
    }
}

/// Observable game stats for the HUD. The engine owns gameplay and pushes summary
/// values here; the HUD never drives the engine.
final class GameModel: ObservableObject {
    @Published var status: GameStatus = .idle
    @Published var score: Int = 0
    @Published var lives: Int = 3
    @Published var level: Int = 1
    @Published var biome: Int = 0
    @Published var weaponLevel: Int = 1
    @Published var bombs: Int = 2
    @Published var best: Int = GamePersistence.loadBest()
    @Published var playerShipId: Int = 0
    /// Remaining shield seconds (0 = no shield).
    @Published var shield: Double = 0
    /// Active boss health as 0…1, or -1 when no boss is on screen.
    @Published var bossHealth: Double = -1
    /// Progress to the next boss as 0…1, or -1 once the boss is here.
    @Published var bossProgress: Double = 0
    /// OVERDRIVE super-beam charge 0…1, and whether it's currently firing.
    @Published var superCharge: Double = 1
    @Published var superActive = false
    /// Shield-wall barrier charge 0…1, and whether the wall is currently up.
    @Published var barrierCharge: Double = 1
    @Published var barrierActive = false
    /// Transient centre banner ("LEVEL 2", "BOSS", "GAME OVER").
    @Published var banner: String?
}

/// The persisted resume blob — only small, stable fields.
struct GameSnapshot: Codable {
    var status: GameStatus
    var score: Int
    var lives: Int
    var level: Int
    var biome: Int
    var weaponLevel: Int
    var bombs: Int
    var best: Int
    var playerShipId: Int
    /// Elapsed time within the current level — the spawner resumes from here.
    var levelTime: Double
    var playerX: Float
    var playerY: Float
    /// Bolt-on weapon mounts (MountWeapon raw values), so resume keeps stacked firepower.
    /// Optional → old saves without it decode fine (treated as no mounts).
    var mountKinds: [Int]?
}

enum GamePersistence {
    private static let stateKey = "inbox2_spaceshooter_state"
    private static let bestKey = "inbox2_spaceshooter_best"

    static func save(_ s: GameSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }

    /// Load a resumable snapshot. Returns nil if absent or the saved run had ended.
    static func load() -> GameSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let s = try? JSONDecoder().decode(GameSnapshot.self, from: data),
              s.status == .playing || s.status == .paused else { return nil }
        return s
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: stateKey) }

    static func loadBest() -> Int { UserDefaults.standard.integer(forKey: bestKey) }
    static func saveBest(_ v: Int) { UserDefaults.standard.set(v, forKey: bestKey) }
}
