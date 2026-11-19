package com.inbox2.app.game

/**
 * The arsenal — four weapons on a gradual power curve. They all share the same
 * destruction model and differ only in carve radius, fire cadence, and projectile feel.
 * Hitting the golden egg with ANY of them wins the level.
 */
enum class Weapon(
    val label: String,
    val carveRadius: Int,    // sphere radius in voxels
    val cooldown: Float,     // seconds between shots
    val muzzleSpeed: Float,  // projectile travel speed (voxels/s)
    val asset: String,       // PNG under assets/game/
    val tracer: Long,        // tracer colour 0xRRGGBB
) {
    PISTOL("Pistol", 1, 0.18f, 90f, "game/weapon_pistol.png", 0xFFE9A0),
    ROCKET("Rocket", 3, 0.65f, 55f, "game/weapon_rocket.png", 0xFF7A3C),
    HEAVY("Heavy", 5, 1.10f, 45f, "game/weapon_heavy.png", 0xFF4242),
    BOMB("Cluster", 8, 1.90f, 38f, "game/weapon_bomb.png", 0x9D5CFF);

    companion object {
        val ordered = entries.toList()
    }
}
