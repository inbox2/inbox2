package com.inbox2.app.game

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * The destructible voxel world for VOXEL STRIKE.
 *
 * A fixed [SX]x[SY]x[SZ] grid in one flat [ByteArray] (material id per cell, 0 = air),
 * generated procedurally from a seeded hash-noise heightmap. The bottom layer (y == 0)
 * is immovable bedrock. A single hidden golden-egg voxel is buried somewhere inside.
 *
 * Destruction is cheap and fake — not physics:
 *  - [carveSphere] removes a sphere of voxels around an impact.
 *  - [computeUnsupported] flood-fills support from the bedrock and returns every solid
 *    voxel no longer connected to the ground (it falls).
 *  - [stepGravity] drops falling voxels straight down one cell per tick until they land.
 *
 * Everything is allocated once up front; the hot loops do no per-call allocation beyond
 * the work queues, which are reused. The heavy [computeUnsupported] flood-fill is meant to
 * run off the render thread (see [VoxelGame]); meshing reads the grid on the GL thread.
 */
class VoxelWorld {

    companion object {
        const val SX = 128
        const val SY = 64
        const val SZ = 128
        const val COUNT = SX * SY * SZ

        // Materials (0 = air). Kept here as the single source of truth for ids.
        const val AIR: Byte = 0
        const val BEDROCK: Byte = 1
        const val STONE: Byte = 2
        const val DIRT: Byte = 3
        const val GRASS: Byte = 4
        const val SAND: Byte = 5
        const val WATER: Byte = 6
        const val EGG: Byte = 7

        const val SEA_LEVEL = 22

        /** Below this many supporting voxels a connection is "too thin" and snaps. */
        const val MIN_NECK = 3

        inline fun idx(x: Int, y: Int, z: Int): Int = (y * SZ + z) * SX + x
        inline fun inBounds(x: Int, y: Int, z: Int): Boolean =
            x in 0 until SX && y in 0 until SY && z in 0 until SZ
    }

    /** material id per cell. */
    val voxels = ByteArray(COUNT)

    /** Surface height (top solid y) per column, for spawn + egg burial + hint. */
    private val heightMap = IntArray(SX * SZ)

    var eggX = 0; private set
    var eggY = 0; private set
    var eggZ = 0; private set
    var eggDestroyed = false; private set

    /** The current level's biome — drives palette, sky/fog (renderer) and terrain shape. */
    var biome: Biome = Biomes.all[0]; private set

    // Reused scratch for the support flood-fill (no per-call allocation).
    private val visited = ByteArray(COUNT)
    private val queue = IntArray(COUNT)
    private var visitedEpoch: Byte = 0

    fun material(x: Int, y: Int, z: Int): Byte =
        if (inBounds(x, y, z)) voxels[idx(x, y, z)] else AIR

    fun solid(x: Int, y: Int, z: Int): Boolean = material(x, y, z) != AIR

    fun surfaceHeight(x: Int, z: Int): Int =
        if (x in 0 until SX && z in 0 until SZ) heightMap[z * SX + x] else SEA_LEVEL

    // ---- Generation -------------------------------------------------------

    /** (Re)generate the whole world for [level]'s biome from [seed]; egg buried deeper each level. */
    fun generate(seed: Long, level: Int) {
        biome = Biomes.forLevel(level)
        java.util.Arrays.fill(voxels, AIR)
        val h = Hash(seed)
        val sea = if (biome.hasLiquid) biome.seaLevel else -1

        for (z in 0 until SZ) {
            for (x in 0 until SX) {
                // Two octaves of value noise → rolling terrain, shaped by the biome.
                val n = h.valueNoise(x * 0.045, z * 0.045) * 0.66 +
                        h.valueNoise(x * 0.12 + 19.0, z * 0.12 - 7.0) * 0.34
                val height = (biome.baseHeight + n * biome.amplitude).toInt().coerceIn(2, SY - 6)
                heightMap[z * SX + x] = height

                for (y in 0..height) {
                    val m = when {
                        y == 0 -> BEDROCK
                        y == height && height > sea -> GRASS   // surface cap
                        y >= height - 3 -> DIRT                // subsoil
                        else -> STONE                          // deep
                    }
                    voxels[idx(x, y, z)] = m
                }
                // Liquid fills low ground; rim (sand) lines the shoreline.
                if (sea >= 0 && height < sea) {
                    for (y in height + 1..sea) voxels[idx(x, y, z)] = WATER
                    if (height >= sea - 2) voxels[idx(x, height, z)] = SAND
                }
            }
        }
        buryEgg(h, level)
        eggDestroyed = false
    }

    private fun buryEgg(h: Hash, level: Int) {
        // Pick an inland column, then bury below its surface — deeper each level.
        val margin = 16
        val ex = margin + (h.uint(101) % (SX - 2 * margin))
        val ez = margin + (h.uint(202) % (SZ - 2 * margin))
        val surf = max(heightMap[ez * SX + ex], 2)
        val depth = (4 + level * 2).coerceAtMost(surf - 2)
        val ey = (surf - depth).coerceIn(1, SY - 2)
        eggX = ex; eggY = ey; eggZ = ez
        voxels[idx(ex, ey, ez)] = EGG
    }

    // ---- Raycast (3D DDA) -------------------------------------------------

    class Hit(val x: Int, val y: Int, val z: Int, val material: Byte, val dist: Float)

    /** March a ray through the grid; return the first solid voxel hit, or null. */
    fun raycast(
        ox: Float, oy: Float, oz: Float,
        dx: Float, dy: Float, dz: Float,
        maxDist: Float,
    ): Hit? {
        var x = floor(ox).toInt(); var y = floor(oy).toInt(); var z = floor(oz).toInt()
        val stepX = if (dx > 0) 1 else -1
        val stepY = if (dy > 0) 1 else -1
        val stepZ = if (dz > 0) 1 else -1
        val invDx = if (dx != 0f) 1f / abs(dx) else Float.MAX_VALUE
        val invDy = if (dy != 0f) 1f / abs(dy) else Float.MAX_VALUE
        val invDz = if (dz != 0f) 1f / abs(dz) else Float.MAX_VALUE
        var tMaxX = (if (dx > 0) (x + 1 - ox) else (ox - x)) * invDx
        var tMaxY = (if (dy > 0) (y + 1 - oy) else (oy - y)) * invDy
        var tMaxZ = (if (dz > 0) (z + 1 - oz) else (oz - z)) * invDz
        var t = 0f
        while (t <= maxDist) {
            if (inBounds(x, y, z)) {
                val m = voxels[idx(x, y, z)]
                if (m != AIR && m != WATER) return Hit(x, y, z, m, t)
            } else if (y < 0 || y >= SY) {
                // Allow rays that start above the terrain to descend into bounds.
                if (t > 0 && (x < -1 || x > SX || z < -1 || z > SZ)) return null
            }
            if (tMaxX < tMaxY && tMaxX < tMaxZ) {
                x += stepX; t = tMaxX; tMaxX += invDx
            } else if (tMaxY < tMaxZ) {
                y += stepY; t = tMaxY; tMaxY += invDy
            } else {
                z += stepZ; t = tMaxZ; tMaxZ += invDz
            }
        }
        return null
    }

    // ---- Destruction ------------------------------------------------------

    /**
     * Carve a sphere of radius [r] around (cx,cy,cz). Bedrock and water are left alone.
     * Returns true if the golden egg was inside the blast.
     * [dirtyMin]/[dirtyMax] (size-6 IntArray) receive the affected voxel AABB for re-mesh.
     */
    fun carveSphere(cx: Int, cy: Int, cz: Int, r: Int, dirty: IntArray): Boolean {
        var eggHit = false
        val r2 = r * r
        var minX = SX; var minY = SY; var minZ = SZ; var maxX = -1; var maxY = -1; var maxZ = -1
        val x0 = max(0, cx - r); val x1 = min(SX - 1, cx + r)
        val y0 = max(1, cy - r); val y1 = min(SY - 1, cy + r) // keep bedrock at y==0
        val z0 = max(0, cz - r); val z1 = min(SZ - 1, cz + r)
        for (y in y0..y1) {
            val dy = y - cy
            for (z in z0..z1) {
                val dz = z - cz
                for (x in x0..x1) {
                    val dx = x - cx
                    if (dx * dx + dy * dy + dz * dz > r2) continue
                    val i = idx(x, y, z)
                    val m = voxels[i]
                    if (m == AIR || m == BEDROCK) continue
                    if (m == EGG) { eggHit = true; eggDestroyed = true }
                    voxels[i] = AIR
                    if (x < minX) minX = x; if (y < minY) minY = y; if (z < minZ) minZ = z
                    if (x > maxX) maxX = x; if (y > maxY) maxY = y; if (z > maxZ) maxZ = z
                }
            }
        }
        dirty[0] = minX; dirty[1] = minY; dirty[2] = minZ
        dirty[3] = maxX; dirty[4] = maxY; dirty[5] = maxZ
        return eggHit
    }

    /**
     * Flood-fill support from the bedrock layer (y == 0) through 6-connected solids.
     * Any solid voxel not reached is unsupported and should fall. Connections hanging by
     * fewer than [MIN_NECK] voxels at the ground contact are also cut loose.
     *
     * Returns the flat indices of every unsupported solid voxel (newly freed), or an
     * empty array. Reuses internal scratch buffers — call from a single worker thread.
     */
    fun computeUnsupported(out: ArrayList<Int>) {
        out.clear()
        val epoch = (visitedEpoch + 1).toByte().also { visitedEpoch = it }
        if (epoch.toInt() == 0) { java.util.Arrays.fill(visited, 0); visitedEpoch = 1 }
        val mark = visitedEpoch
        var head = 0; var tail = 0

        // Seed from every solid voxel resting on bedrock.
        for (z in 0 until SZ) for (x in 0 until SX) {
            val i = idx(x, 1, z)
            if (voxels[i] != AIR && voxels[idx(x, 0, z)] == BEDROCK) {
                visited[i] = mark; queue[tail++] = i
            }
        }
        // BFS over connected solids (water is not structural).
        while (head < tail) {
            val i = queue[head++]
            val x = i % SX
            val y = i / (SX * SZ)
            val z = (i / SX) % SZ
            // 6 neighbours
            neighbour(x - 1, y, z, mark)?.let { queue[tail++] = it }
            neighbour(x + 1, y, z, mark)?.let { queue[tail++] = it }
            neighbour(x, y - 1, z, mark)?.let { queue[tail++] = it }
            neighbour(x, y + 1, z, mark)?.let { queue[tail++] = it }
            neighbour(x, y, z - 1, mark)?.let { queue[tail++] = it }
            neighbour(x, y, z + 1, mark)?.let { queue[tail++] = it }
        }
        // Anything solid + structural that wasn't reached is unsupported.
        for (i in 0 until COUNT) {
            val m = voxels[i]
            if (m != AIR && m != BEDROCK && m != WATER && visited[i] != mark) out.add(i)
        }
    }

    private fun neighbour(x: Int, y: Int, z: Int, mark: Byte): Int? {
        if (!inBounds(x, y, z)) return null
        val i = idx(x, y, z)
        if (visited[i] == mark) return null
        val m = voxels[i]
        if (m == AIR || m == WATER) return null
        visited[i] = mark
        return i
    }

    fun clear(i: Int) { voxels[i] = AIR }
    fun set(i: Int, m: Byte) { voxels[i] = m }
    fun isAir(i: Int): Boolean = voxels[i] == AIR
}

/** Small deterministic integer/value-noise hash (fixed seed → identical worlds). */
class Hash(seed: Long) {
    private val s = seed * 0x9E3779B97F4A7C15uL.toLong()
    fun uint(n: Int): Int {
        var h = (s xor (n.toLong() * -0x61c8864680b583ebL))
        h = h xor (h ushr 30); h *= -0x40a7b892e31b1a47L
        h = h xor (h ushr 27); h *= -0x6b2fb644ecceee15L
        h = h xor (h ushr 31)
        return (h and 0x7fffffff).toInt()
    }
    private fun cell(ix: Int, iz: Int): Double {
        var h = s xor (ix.toLong() * -0x61c8864680b583ebL) xor (iz.toLong() * 0x27d4eb2f165667c5L)
        h = h xor (h ushr 33); h *= -0xae502812aa7333L; h = h xor (h ushr 29)
        return ((h and 0xffffff).toDouble() / 0xffffff.toDouble())
    }
    fun valueNoise(x: Double, z: Double): Double {
        val x0 = floor(x).toInt(); val z0 = floor(z).toInt()
        val fx = x - x0; val fz = z - z0
        val sx = fx * fx * (3 - 2 * fx); val sz = fz * fz * (3 - 2 * fz)
        val a = cell(x0, z0); val b = cell(x0 + 1, z0)
        val c = cell(x0, z0 + 1); val d = cell(x0 + 1, z0 + 1)
        val ab = a + (b - a) * sx; val cd = c + (d - c) * sx
        return ab + (cd - ab) * sz
    }
}
