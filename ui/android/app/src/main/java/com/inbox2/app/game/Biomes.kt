package com.inbox2.app.game

/**
 * Per-level biome: same voxel mechanics, totally different world. A biome re-colours the
 * five terrain roles (the mesher maps GRASS→surface, its sides→surfaceSide, DIRT→subsoil,
 * STONE→deep, SAND→rim, WATER→liquid), swaps the sky + distance fog, and reshapes the
 * heightmap (base height / amplitude / sea level). The golden egg stays gold everywhere.
 *
 * Levels cycle through [all] (level 1 → grassland, 2 → sea, 3 → space, …, 11 → grassland).
 * Colours are 0xRRGGBB.
 */
class Biome(
    val name: String,
    val sky: Int,
    val surface: Int,      // grass-block top
    val surfaceSide: Int,  // grass-block sides (under the cap)
    val subsoil: Int,      // dirt
    val deep: Int,         // stone
    val rim: Int,          // shoreline sand
    val liquid: Int,       // water/lava/toxic…
    val bedrock: Int,
    val hasLiquid: Boolean,
    val seaLevel: Int,
    val baseHeight: Int,
    val amplitude: Int,
    val fogStart: Float,
    val fogEnd: Float,
) {
    fun skyRGB(): FloatArray = floatArrayOf(
        ((sky shr 16) and 0xFF) / 255f, ((sky shr 8) and 0xFF) / 255f, (sky and 0xFF) / 255f,
    )
}

object Biomes {
    val all: List<Biome> = listOf(
        // 1 — Grassland: the classic green world.
        Biome("GRASSLAND", 0x82C4ED, 0x5FAE3A, 0x6B4A2C, 0x7A5532, 0x8A8F98, 0xD9C77A,
            0x2E6CC7, 0x2B2F36, hasLiquid = true, seaLevel = 22, baseHeight = 18, amplitude = 26,
            fogStart = 75f, fogEnd = 165f),
        // 2 — Sea / archipelago: high water, scattered sandy islands.
        Biome("ARCHIPELAGO", 0x9FD8F0, 0x63B848, 0xCBB86E, 0xCBB86E, 0x9AA0A8, 0xE6D695,
            0x1E8AD6, 0x2B2F36, hasLiquid = true, seaLevel = 20, baseHeight = 10, amplitude = 18,
            fogStart = 80f, fogEnd = 175f),
        // 3 — Space / asteroid: black void sky, no liquid, grey rock.
        Biome("ASTEROID", 0x070710, 0x6B6B7A, 0x4A4A57, 0x44444F, 0x33333E, 0x7A6E58,
            0x5A4AA0, 0x16161E, hasLiquid = false, seaLevel = 0, baseHeight = 16, amplitude = 30,
            fogStart = 70f, fogEnd = 200f),
        // 4 — Desert: dunes, hazy sky, no water.
        Biome("DESERT", 0xE9D9A8, 0xE0C878, 0xCBA85A, 0xCBA85A, 0xB89050, 0xEAD9A0,
            0x4FA0C8, 0x4A4030, hasLiquid = false, seaLevel = 0, baseHeight = 16, amplitude = 14,
            fogStart = 70f, fogEnd = 160f),
        // 5 — Snow / tundra: snow caps, ice water, pale sky.
        Biome("TUNDRA", 0xD8E8F2, 0xF0F4FA, 0xCFE0EC, 0xC2D2DE, 0x90A0AC, 0xE4EEF4,
            0x7FB6DC, 0x44505A, hasLiquid = true, seaLevel = 20, baseHeight = 18, amplitude = 20,
            fogStart = 60f, fogEnd = 150f),
        // 6 — Volcanic: basalt, glowing lava seas, ashen sky.
        Biome("VOLCANO", 0x3A2A2A, 0x4A3A40, 0x3A3036, 0x46383E, 0x2A2226, 0x8A3A20,
            0xFF5A1E, 0x1A1416, hasLiquid = true, seaLevel = 19, baseHeight = 16, amplitude = 28,
            fogStart = 65f, fogEnd = 150f),
        // 7 — Toxic swamp: mossy ground, radioactive sludge.
        Biome("TOXIC SWAMP", 0x59663A, 0x4D6B2A, 0x3A4A22, 0x40521F, 0x2A331A, 0x5A5A2A,
            0x8FD62A, 0x1E2414, hasLiquid = true, seaLevel = 17, baseHeight = 12, amplitude = 12,
            fogStart = 55f, fogEnd = 130f),
        // 8 — Alien crystal: purple rock, teal pools, magenta sky.
        Biome("ALIEN", 0x2A1040, 0x8A3AAA, 0x5A2A7A, 0x5A2A7A, 0x3A1A55, 0xC060E0,
            0x30D0C0, 0x18092A, hasLiquid = true, seaLevel = 20, baseHeight = 16, amplitude = 30,
            fogStart = 70f, fogEnd = 170f),
        // 9 — Candy: pastel everything.
        Biome("CANDY", 0xFAD0E8, 0xFF8AC0, 0xFFC04A, 0xE89AD0, 0xC060A0, 0xFFF0A0,
            0x60D0FF, 0xB05088, hasLiquid = true, seaLevel = 21, baseHeight = 18, amplitude = 22,
            fogStart = 80f, fogEnd = 175f),
        // 10 — Obsidian void: near-black glass, purple-energy pools, gold veins.
        Biome("OBSIDIAN VOID", 0x0C0C16, 0x1E1E2A, 0x26262F, 0x26262F, 0x14141C, 0xC0A040,
            0x6A30C0, 0x08080C, hasLiquid = true, seaLevel = 18, baseHeight = 18, amplitude = 26,
            fogStart = 70f, fogEnd = 190f),
    )

    fun forLevel(level: Int): Biome = all[((level - 1) % all.size + all.size) % all.size]
}
