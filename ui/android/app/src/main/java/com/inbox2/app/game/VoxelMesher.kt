package com.inbox2.app.game

import com.inbox2.app.game.VoxelWorld.Companion.AIR
import com.inbox2.app.game.VoxelWorld.Companion.EGG
import com.inbox2.app.game.VoxelWorld.Companion.SX
import com.inbox2.app.game.VoxelWorld.Companion.SY
import com.inbox2.app.game.VoxelWorld.Companion.SZ
import com.inbox2.app.game.VoxelWorld.Companion.WATER

/**
 * Greedy-ish face-culled mesher. The world is split into [CHUNK]x[SY]x[CHUNK] columns;
 * each chunk owns one interleaved vertex buffer `[x,y,z, r,g,b]` and is re-meshed only
 * when dirtied by a destruction pass. Only faces between a solid voxel and air/water are
 * emitted — interior faces never reach the GPU.
 */
object VoxelMesher {
    const val CHUNK = 16
    const val CHUNKS_X = SX / CHUNK
    const val CHUNKS_Z = SZ / CHUNK
    const val CHUNK_COUNT = CHUNKS_X * CHUNKS_Z
    const val STRIDE = 6 // floats per vertex

    // Classic voxel cheap-light: top brightest, bottom darkest, sides between.
    private const val TOP = 1.0f
    private const val BOTTOM = 0.45f
    private const val SIDE_X = 0.66f
    private const val SIDE_Z = 0.82f

    fun chunkIndex(cx: Int, cz: Int) = cz * CHUNKS_X + cx

    // The biome whose palette the colour lookup uses. Meshing is single-threaded (GL
    // thread), so a field is safe and avoids threading it through every face call.
    private var biome: Biome = Biomes.all[0]

    /** Mesh one chunk into [mesh], reusing/growing its float buffer. */
    fun mesh(world: VoxelWorld, cx: Int, cz: Int, mesh: ChunkMesh) {
        biome = world.biome
        val v = mesh.begin()
        val baseX = cx * CHUNK
        val baseZ = cz * CHUNK
        for (y in 0 until SY) {
            for (lz in 0 until CHUNK) {
                val z = baseZ + lz
                for (lx in 0 until CHUNK) {
                    val x = baseX + lx
                    val m = world.material(x, y, z)
                    if (m == AIR) continue
                    val opaque = m != WATER
                    // +Y (top)
                    if (!occludes(world.material(x, y + 1, z), m))
                        v.face(x, y, z, FACE_TOP, m, TOP)
                    // -Y (bottom)
                    if (y > 0 && !occludes(world.material(x, y - 1, z), m))
                        v.face(x, y, z, FACE_BOTTOM, m, BOTTOM)
                    // +X / -X
                    if (!occludes(world.material(x + 1, y, z), m))
                        v.face(x, y, z, FACE_PX, m, SIDE_X)
                    if (!occludes(world.material(x - 1, y, z), m))
                        v.face(x, y, z, FACE_NX, m, SIDE_X * 0.92f)
                    // +Z / -Z
                    if (!occludes(world.material(x, y, z + 1), m))
                        v.face(x, y, z, FACE_PZ, m, SIDE_Z)
                    if (!occludes(world.material(x, y, z - 1), m))
                        v.face(x, y, z, FACE_NZ, m, SIDE_Z * 0.9f)
                    if (!opaque) Unit
                }
            }
        }
        mesh.end()
    }

    /** Does neighbour material [n] hide the face of self material [s]? */
    private fun occludes(n: Byte, s: Byte): Boolean = when (n) {
        AIR -> false
        WATER -> s == WATER
        else -> true
    }

    // Face vertex offsets (unit cube), CCW when viewed from outside.
    private const val FACE_TOP = 0
    private const val FACE_BOTTOM = 1
    private const val FACE_PX = 2
    private const val FACE_NX = 3
    private const val FACE_PZ = 4
    private const val FACE_NZ = 5

    /** Base material colour 0xRRGGBB before face shading — biome-driven; egg always gold. */
    fun materialColor(m: Byte, top: Boolean): Int = when (m) {
        VoxelWorld.BEDROCK -> biome.bedrock
        VoxelWorld.STONE -> biome.deep
        VoxelWorld.DIRT -> biome.subsoil
        VoxelWorld.GRASS -> if (top) biome.surface else biome.surfaceSide
        VoxelWorld.SAND -> biome.rim
        VoxelWorld.WATER -> biome.liquid
        EGG -> 0xFFD23F
        else -> 0xFF00FF
    }

    private fun ChunkMesh.face(x: Int, y: Int, z: Int, face: Int, m: Byte, shade: Float) {
        val top = face == FACE_TOP
        val c = materialColor(m, top)
        var r = ((c shr 16) and 0xFF) / 255f * shade
        var g = ((c shr 8) and 0xFF) / 255f * shade
        var b = (c and 0xFF) / 255f * shade
        if (m == EGG) { r = minOf(1f, r + 0.25f); g = minOf(1f, g + 0.2f) } // egg glints
        val fx = x.toFloat(); val fy = y.toFloat(); val fz = z.toFloat()
        // Two triangles (6 verts) per face.
        when (face) {
            FACE_TOP -> quad(fx,fy+1,fz, fx+1,fy+1,fz, fx+1,fy+1,fz+1, fx,fy+1,fz+1, r,g,b)
            FACE_BOTTOM -> quad(fx,fy,fz+1, fx+1,fy,fz+1, fx+1,fy,fz, fx,fy,fz, r,g,b)
            FACE_PX -> quad(fx+1,fy,fz, fx+1,fy,fz+1, fx+1,fy+1,fz+1, fx+1,fy+1,fz, r,g,b)
            FACE_NX -> quad(fx,fy,fz+1, fx,fy,fz, fx,fy+1,fz, fx,fy+1,fz+1, r,g,b)
            FACE_PZ -> quad(fx+1,fy,fz+1, fx,fy,fz+1, fx,fy+1,fz+1, fx+1,fy+1,fz+1, r,g,b)
            FACE_NZ -> quad(fx,fy,fz, fx+1,fy,fz, fx+1,fy+1,fz, fx,fy+1,fz, r,g,b)
        }
    }
}
