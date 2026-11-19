import SceneKit
import UIKit

// Background biomes. Each defines the synthwave colour scheme for the scrolling grid
// floor, the far gradient backdrop, the distance fog, and the star/parallax tint. The
// engine cycles biomes as levels advance.

struct Biome {
    let name: String
    let grid: UIColor
    let bgTop: UIColor
    let bgBottom: UIColor
    let sun: UIColor
    let fog: UIColor
    let star: UIColor

    static let all: [Biome] = [
        Biome(name: "NEON CITY",
              grid: Synth.magenta, bgTop: UIColor(red: 0.04, green: 0.02, blue: 0.12, alpha: 1),
              bgBottom: UIColor(red: 0.22, green: 0.04, blue: 0.30, alpha: 1),
              sun: Synth.magenta, fog: UIColor(red: 0.10, green: 0.03, blue: 0.18, alpha: 1),
              star: Synth.aqua),
        Biome(name: "CRYSTAL CANYON",
              grid: Synth.violet, bgTop: UIColor(red: 0.06, green: 0.02, blue: 0.10, alpha: 1),
              bgBottom: UIColor(red: 0.30, green: 0.06, blue: 0.20, alpha: 1),
              sun: Synth.cyan, fog: UIColor(red: 0.14, green: 0.03, blue: 0.14, alpha: 1),
              star: Synth.pink),
        Biome(name: "REACTOR",
              grid: Synth.amber, bgTop: UIColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1),
              bgBottom: UIColor(red: 0.04, green: 0.20, blue: 0.28, alpha: 1),
              sun: Synth.violet, fog: UIColor(red: 0.03, green: 0.10, blue: 0.16, alpha: 1),
              star: Synth.cyan),
        Biome(name: "SUN GRID",
              grid: Synth.pink, bgTop: UIColor(red: 0.10, green: 0.02, blue: 0.14, alpha: 1),
              bgBottom: UIColor(red: 0.40, green: 0.10, blue: 0.16, alpha: 1),
              sun: Synth.amber, fog: UIColor(red: 0.16, green: 0.04, blue: 0.12, alpha: 1),
              star: Synth.amber),
    ]

    static func at(_ index: Int) -> Biome { all[((index % all.count) + all.count) % all.count] }
}
