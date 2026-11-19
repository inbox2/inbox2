package com.inbox2.app.game

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

enum class GameStatus { START, PLAYING, LEVEL_COMPLETE }

/** Immutable HUD snapshot handed to Compose (updated off the GL thread via the main handler). */
data class Hud(
    val status: GameStatus = GameStatus.START,
    val level: Int = 1,
    val score: Int = 0,
    val weaponIndex: Int = Weapon.ROCKET.ordinal,
    val eggHint: Float = 1f,      // 0 = right on top of it, 1 = far / cold
    val eggExposed: Boolean = false,
    val settling: Boolean = false,
    val biome: String = "",
)

/**
 * The simulation: a free-fly camera over a destructible [VoxelWorld], a switchable arsenal,
 * rocket-style projectiles fired exactly along the view direction, and the golden-egg →
 * next-level loop. [update] runs on the GL thread; the heavy support flood-fill is offloaded
 * to a single worker thread and its result applied back on the GL thread (writes never race
 * the reads, see the physics state machine below).
 */
class VoxelGame {
    val world = VoxelWorld()

    // Camera
    var camX = 64f; var camY = 40f; var camZ = 110f
    var yaw = 0f; var pitch = -0.35f

    // Level / score
    var level = 1; private set
    var score = 0; private set
    var status = GameStatus.START; private set
    var weapon = Weapon.ROCKET; private set

    // ---- Input intents (written from the UI thread, read on the GL thread) ----
    @Volatile private var moveX = 0f      // strafe [-1,1]
    @Volatile private var moveY = 0f      // forward [-1,1]
    @Volatile private var floating = false
    @Volatile private var sinking = false
    @Volatile private var fireHeld = false
    @Volatile private var fireQueued = false   // latched on press so a fast tap can't fall between frames
    private val pendingLook = floatArrayOf(0f, 0f)
    private val lookLock = Any()

    // ---- HUD (Compose) ----
    var hud by mutableStateOf(Hud())
        private set
    private val main = Handler(Looper.getMainLooper())

    // ---- Projectiles ----
    private class Shot(
        var x: Float, var y: Float, var z: Float,
        val dx: Float, val dy: Float, val dz: Float,
        val speed: Float, val maxDist: Float, val radius: Int,
        val color: Long, var traveled: Float = 0f, var alive: Boolean = true,
    )
    private val shots = ArrayList<Shot>()
    private var cooldown = 0f

    // ---- Falling voxels (grid gravity) ----
    private val falling = ArrayList<Int>()       // flat indices currently dropping
    private var gravityAccum = 0f

    // ---- Destruction worker / state machine ----
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var physicsBusy = false
    private val pendingUnsupported = AtomicReference<ArrayList<Int>?>(null)
    private val scratchUnsupported = ArrayList<Int>(8192)
    private val dirty = IntArray(6)
    private val queuedImpacts = ArrayList<IntArray>()  // [vx,vy,vz,radius] deferred while busy

    /** Chunks needing a re-mesh (drained by the renderer). */
    val dirtyChunks = HashSet<Int>()

    // ---------------------------------------------------------------------

    // Level (re)gen rewrites the whole grid — it MUST run on the GL thread, never the UI
    // thread that taps the buttons, or it races the renderer's mesh reads. The public
    // entry points just queue a request; [update] pumps it at the top of the GL frame.
    @Volatile private var pendingStart: (() -> Unit)? = null

    fun nextLevel() { pendingStart = { doStartLevel(level + 1, keepScore = true) } }
    fun newGame() { pendingStart = { doStartLevel(1, keepScore = false) } }
    fun continueFrom(savedLevel: Int, savedScore: Int) {
        pendingStart = { score = savedScore; doStartLevel(savedLevel, keepScore = true) }
    }

    private fun doStartLevel(newLevel: Int, keepScore: Boolean) {
        level = newLevel
        if (!keepScore) score = 0
        world.generate(seedFor(level), level)
        // Spawn high, overlooking the terrain, looking across the map.
        camX = VoxelWorld.SX * 0.5f
        camZ = VoxelWorld.SZ * 0.86f
        camY = world.surfaceHeight(camX.toInt(), camZ.toInt()) + 20f
        yaw = 0f; pitch = -0.32f
        shots.clear(); falling.clear(); queuedImpacts.clear()
        physicsBusy = false; cooldown = 0f
        status = GameStatus.PLAYING
        for (c in 0 until VoxelMesher.CHUNK_COUNT) dirtyChunks.add(c)
        pushHud()
    }

    private fun seedFor(lvl: Int): Long = START_SEED xor (lvl.toLong() * -0x61c8864680b583ebL)

    // ---- Input API (UI thread) ----
    fun setMove(x: Float, y: Float) { moveX = x.coerceIn(-1f, 1f); moveY = y.coerceIn(-1f, 1f) }
    fun setFloating(up: Boolean) { floating = up }
    fun setSinking(down: Boolean) { sinking = down }
    fun setFire(held: Boolean) { fireHeld = held; if (held) fireQueued = true }
    fun addLook(dx: Float, dy: Float) { synchronized(lookLock) { pendingLook[0] += dx; pendingLook[1] += dy } }
    fun selectWeapon(w: Weapon) { weapon = w; pushHud() }
    fun cycleWeapon() { weapon = Weapon.ordered[(weapon.ordinal + 1) % Weapon.ordered.size]; pushHud() }

    // ---------------------------------------------------------------------

    fun update(dt: Float) {
        // Pump a queued level (re)gen on the GL thread before anything reads the grid.
        pendingStart?.let { it(); pendingStart = null }
        if (status != GameStatus.PLAYING) return

        // Look
        var dLook0: Float; var dLook1: Float
        synchronized(lookLock) { dLook0 = pendingLook[0]; dLook1 = pendingLook[1]; pendingLook[0] = 0f; pendingLook[1] = 0f }
        yaw += dLook0
        pitch = (pitch - dLook1).coerceIn(-1.54f, 1.54f)

        // Forward / right from yaw+pitch (yaw 0 looks toward -Z).
        val cp = cos(pitch); val sp = sin(pitch); val sy = sin(yaw); val cy = cos(yaw)
        val fx = sy * cp; val fy = sp; val fz = -cy * cp
        val rx = cy; val rz = sy

        // Move (forward uses full view vector so pitching down lets you fly into tunnels).
        val speed = 24f * dt
        camX += (fx * moveY + rx * moveX) * speed
        camY += (fy * moveY) * speed
        camZ += (fz * moveY + rz * moveX) * speed
        if (floating) camY += 17f * dt
        if (sinking) camY -= 17f * dt
        camX = camX.coerceIn(1f, VoxelWorld.SX - 1f)
        camZ = camZ.coerceIn(1f, VoxelWorld.SZ - 1f)
        camY = camY.coerceIn(1.4f, VoxelWorld.SY + 24f)

        // Fire — auto-fire while held, plus a one-shot latched request so a fast tap fires.
        cooldown -= dt
        if ((fireHeld || fireQueued) && cooldown <= 0f) {
            fire(fx, fy, fz); cooldown = weapon.cooldown; fireQueued = false
        }

        // Advance projectiles
        var i = 0
        while (i < shots.size) {
            val s = shots[i]
            s.traveled += s.speed * dt
            s.x += s.dx * s.speed * dt; s.y += s.dy * s.speed * dt; s.z += s.dz * s.speed * dt
            if (s.traveled >= s.maxDist) { impact(s); shots.removeAt(i) } else i++
        }

        // Apply any finished support-fill, then settle gravity over time.
        drainPhysics()
        stepGravity(dt)

        // Egg hint + exposure → HUD (throttled inside pushHud()).
        maybePushHud(dt)
    }

    private fun fire(fx: Float, fy: Float, fz: Float) {
        val hit = world.raycast(camX, camY, camZ, fx, fy, fz, 200f)
        val maxDist = hit?.dist ?: 200f
        shots.add(Shot(camX, camY, camZ, fx, fy, fz, weapon.muzzleSpeed, maxDist, weapon.carveRadius, weapon.tracer))
    }

    private fun impact(s: Shot) {
        // Land the carve on the voxel the ray ended in.
        val vx = (s.x).toInt(); val vy = (s.y).toInt(); val vz = (s.z).toInt()
        queueImpact(vx, vy, vz, s.radius)
    }

    private fun queueImpact(vx: Int, vy: Int, vz: Int, radius: Int) {
        if (physicsBusy) { queuedImpacts.add(intArrayOf(vx, vy, vz, radius)); return }
        val eggHit = world.carveSphere(vx, vy, vz, radius, dirty)
        markDirtyAabb()
        score += radius * radius
        if (eggHit && status == GameStatus.PLAYING) { winLevel(); return }
        // Off-thread: find everything no longer supported.
        physicsBusy = true
        worker.execute {
            world.computeUnsupported(scratchUnsupported)
            pendingUnsupported.set(ArrayList(scratchUnsupported))
        }
    }

    private fun drainPhysics() {
        val res = pendingUnsupported.getAndSet(null) ?: return
        falling.addAll(res)
        // Re-mesh everything the freed voxels touch so they disappear from their old home.
        for (idx in res) markChunkForIndex(idx)
        physicsBusy = false
        // Process one queued impact (if any) now that the worker is free.
        if (queuedImpacts.isNotEmpty()) {
            val q = queuedImpacts.removeAt(0)
            queueImpact(q[0], q[1], q[2], q[3])
        }
    }

    private fun stepGravity(dt: Float) {
        if (falling.isEmpty()) return
        gravityAccum += dt
        val tick = 1f / 14f  // ~14 fall-steps per second reads as tumbling rubble
        while (gravityAccum >= tick) {
            gravityAccum -= tick
            falling.sortBy { it / (VoxelWorld.SX * VoxelWorld.SZ) } // ascending y so lower cells move first
            var i = 0
            while (i < falling.size) {
                val idx = falling[i]
                val y = idx / (VoxelWorld.SX * VoxelWorld.SZ)
                val below = idx - VoxelWorld.SX * VoxelWorld.SZ
                if (y > 1 && world.isAir(below)) {
                    val m = world.voxels[idx]
                    world.set(below, m); world.clear(idx)
                    markChunkForIndex(idx); markChunkForIndex(below)
                    falling[i] = below
                    i++
                } else {
                    falling.removeAt(i) // landed
                }
            }
            if (falling.isEmpty()) break
        }
    }

    private fun winLevel() {
        status = GameStatus.LEVEL_COMPLETE
        score += 1000 * level
        shots.clear()
        pushHud()
    }

    // ---- dirty-chunk bookkeeping ----
    private fun markDirtyAabb() {
        if (dirty[3] < 0) return
        val cx0 = dirty[0] / VoxelMesher.CHUNK; val cx1 = dirty[3] / VoxelMesher.CHUNK
        val cz0 = dirty[2] / VoxelMesher.CHUNK; val cz1 = dirty[5] / VoxelMesher.CHUNK
        for (cz in cz0..cz1) for (cx in cx0..cx1)
            dirtyChunks.add(VoxelMesher.chunkIndex(cx, cz))
    }

    private fun markChunkForIndex(idx: Int) {
        val x = idx % VoxelWorld.SX
        val z = (idx / VoxelWorld.SX) % VoxelWorld.SZ
        dirtyChunks.add(VoxelMesher.chunkIndex(x / VoxelMesher.CHUNK, z / VoxelMesher.CHUNK))
    }

    // ---- HUD ----
    private var hudAccum = 0f
    private fun maybePushHud(dt: Float) {
        hudAccum += dt
        if (hudAccum < 0.12f) return
        hudAccum = 0f
        pushHud()
    }

    private fun pushHud() {
        val dx = camX - world.eggX; val dy = camY - world.eggY; val dz = camZ - world.eggZ
        val dist = sqrt(dx * dx + dy * dy + dz * dz)
        val hint = (dist / 140f).coerceIn(0f, 1f)
        val exposed = !world.eggDestroyed && eggExposed()
        val snap = Hud(status, level, score, weapon.ordinal, hint, exposed, falling.isNotEmpty(), world.biome.name)
        main.post { hud = snap }
    }

    private fun eggExposed(): Boolean {
        val x = world.eggX; val y = world.eggY; val z = world.eggZ
        return world.material(x, y + 1, z) == VoxelWorld.AIR ||
            world.material(x + 1, y, z) == VoxelWorld.AIR ||
            world.material(x - 1, y, z) == VoxelWorld.AIR ||
            world.material(x, y, z + 1) == VoxelWorld.AIR ||
            world.material(x, y, z - 1) == VoxelWorld.AIR ||
            world.material(x, y - 1, z) == VoxelWorld.AIR
    }

    /** Renderer overlay reads: live projectiles (for tracers) and egg highlight pulse. */
    fun forEachShot(action: (x: Float, y: Float, z: Float, color: Long) -> Unit) {
        for (s in shots) action(s.x, s.y, s.z, s.color)
    }

    fun dispose() { worker.shutdownNow() }

    companion object { private const val START_SEED = 0x5715EL }
}
