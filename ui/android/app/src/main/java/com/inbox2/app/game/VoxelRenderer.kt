package com.inbox2.app.game

import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.cos
import kotlin.math.sin

/**
 * Software-fed, GPU-rasterised voxel renderer. Each dirty chunk is re-meshed on the GL
 * thread (capped per frame so a fresh level streams in instead of hitching), uploaded to a
 * per-chunk VBO, and drawn with a tiny flat-colour + distance-fog shader. A small dynamic
 * buffer draws projectile tracers and the golden-egg highlight on top.
 *
 * The image is upright (standard projection, no manual framebuffer flip) and shots travel
 * exactly along the camera's view direction (see [VoxelGame.fire]).
 */
class VoxelRenderer(private val game: VoxelGame) : GLSurfaceView.Renderer {

    private val meshes = Array(VoxelMesher.CHUNK_COUNT) { ChunkMesh() }
    private val overlay = ChunkMesh()
    private var overlayVbo = 0

    private var program = 0
    private var aPos = 0; private var aColor = 0
    private var uMVP = 0; private var uCam = 0; private var uSky = 0
    private var uFogStart = 0; private var uFogEnd = 0

    private val proj = FloatArray(16)
    private val view = FloatArray(16)
    private val mvp = FloatArray(16)

    private var lastNanos = 0L
    private var pulse = 0f
    private var aspect = 1.7778f

    private var scratch: FloatBuffer =
        ByteBuffer.allocateDirect(262144 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

    @Volatile var lastFps = 0f; private set

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES20.glClearColor(SKY_R, SKY_G, SKY_B, 1f)
        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        // No back-face culling: the mesher already emits only solid↔air boundary quads, so
        // every face is meant to be seen. Culling here only risked winding-dependent
        // see-through (terraced faces vanishing); depth-test keeps the result correct.
        GLES20.glDisable(GLES20.GL_CULL_FACE)

        program = link(VERT, FRAG)
        aPos = GLES20.glGetAttribLocation(program, "aPos")
        aColor = GLES20.glGetAttribLocation(program, "aColor")
        uMVP = GLES20.glGetUniformLocation(program, "uMVP")
        uCam = GLES20.glGetUniformLocation(program, "uCam")
        uSky = GLES20.glGetUniformLocation(program, "uSky")
        uFogStart = GLES20.glGetUniformLocation(program, "uFogStart")
        uFogEnd = GLES20.glGetUniformLocation(program, "uFogEnd")

        val ids = IntArray(1)
        for (m in meshes) { GLES20.glGenBuffers(1, ids, 0); m.glBuffer = ids[0]; m.glVertexCount = 0; m.dirty = true }
        GLES20.glGenBuffers(1, ids, 0); overlayVbo = ids[0]
        // EGL context (re)created → all VBOs are fresh; re-mesh every populated chunk.
        for (c in 0 until VoxelMesher.CHUNK_COUNT) game.dirtyChunks.add(c)
        lastNanos = System.nanoTime()
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES20.glViewport(0, 0, width, height)
        aspect = width.toFloat() / height.coerceAtLeast(1)
        Matrix.perspectiveM(proj, 0, 62f, aspect, 0.1f, 360f)
    }

    override fun onDrawFrame(gl: GL10?) {
        val now = System.nanoTime()
        var dt = (now - lastNanos) / 1e9f
        lastNanos = now
        if (dt > 0.05f) dt = 0.05f
        if (dt > 0f) lastFps = 1f / dt
        pulse += dt

        game.update(dt)
        remeshDirty()

        // Sky + fog follow the current level's biome (grassland blue → asteroid void → …).
        val biome = game.world.biome
        val sky = biome.skyRGB()
        GLES20.glClearColor(sky[0], sky[1], sky[2], 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)

        // View matrix from the camera's exact forward (same vector shots use).
        val cp = cos(game.pitch); val sp = sin(game.pitch); val sy = sin(game.yaw); val cy = cos(game.yaw)
        val fx = sy * cp; val fy = sp; val fz = -cy * cp
        Matrix.setLookAtM(view, 0, game.camX, game.camY, game.camZ,
            game.camX + fx, game.camY + fy, game.camZ + fz, 0f, 1f, 0f)
        Matrix.multiplyMM(mvp, 0, proj, 0, view, 0)

        GLES20.glUseProgram(program)
        GLES20.glUniformMatrix4fv(uMVP, 1, false, mvp, 0)
        GLES20.glUniform3f(uCam, game.camX, game.camY, game.camZ)
        GLES20.glUniform3f(uSky, sky[0], sky[1], sky[2])
        GLES20.glUniform1f(uFogStart, biome.fogStart)
        GLES20.glUniform1f(uFogEnd, biome.fogEnd)
        GLES20.glEnableVertexAttribArray(aPos)
        GLES20.glEnableVertexAttribArray(aColor)

        for (m in meshes) drawBuffer(m.glBuffer, m.glVertexCount)
        drawOverlay()

        GLES20.glDisableVertexAttribArray(aPos)
        GLES20.glDisableVertexAttribArray(aColor)
    }

    private fun remeshDirty() {
        if (game.dirtyChunks.isEmpty()) return
        val it = game.dirtyChunks.iterator()
        var budget = MAX_REMESH_PER_FRAME
        while (it.hasNext() && budget-- > 0) {
            val c = it.next(); it.remove()
            val cx = c % VoxelMesher.CHUNKS_X; val cz = c / VoxelMesher.CHUNKS_X
            val mesh = meshes[c]
            VoxelMesher.mesh(game.world, cx, cz, mesh)
            upload(mesh)
        }
    }

    private fun upload(mesh: ChunkMesh) {
        if (mesh.count == 0) { mesh.glVertexCount = 0; mesh.dirty = false; return }
        if (scratch.capacity() < mesh.count)
            scratch = ByteBuffer.allocateDirect(mesh.count * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        scratch.clear(); scratch.put(mesh.verts, 0, mesh.count); scratch.position(0)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, mesh.glBuffer)
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, mesh.count * 4, scratch, GLES20.GL_DYNAMIC_DRAW)
        mesh.glVertexCount = mesh.count / VoxelMesher.STRIDE
        mesh.dirty = false
    }

    private fun drawBuffer(vbo: Int, vertexCount: Int) {
        if (vertexCount == 0) return
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo)
        GLES20.glVertexAttribPointer(aPos, 3, GLES20.GL_FLOAT, false, VoxelMesher.STRIDE * 4, 0)
        GLES20.glVertexAttribPointer(aColor, 3, GLES20.GL_FLOAT, false, VoxelMesher.STRIDE * 4, 12)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, vertexCount)
    }

    private fun drawOverlay() {
        overlay.begin()
        // Projectile tracers — small bright cubes.
        game.forEachShot { x, y, z, color ->
            val r = ((color shr 16) and 0xFF) / 255f
            val g = ((color shr 8) and 0xFF) / 255f
            val b = (color and 0xFF) / 255f
            cube(overlay, x - 0.35f, y - 0.35f, z - 0.35f, x + 0.35f, y + 0.35f, z + 0.35f, r, g, b)
        }
        // Golden-egg highlight — a pulsing oversized gold cube once it's exposed.
        if (game.hud.eggExposed) {
            val p = 0.5f + 0.5f * sin(pulse * 4f)
            val ex = game.world.eggX.toFloat(); val ey = game.world.eggY.toFloat(); val ez = game.world.eggZ.toFloat()
            val m = 0.18f + 0.22f * p
            cube(overlay, ex - m, ey - m, ez - m, ex + 1 + m, ey + 1 + m, ez + 1 + m,
                1f, 0.85f + 0.15f * p, 0.25f)
        }
        overlay.end()
        if (overlay.count == 0) return
        if (scratch.capacity() < overlay.count)
            scratch = ByteBuffer.allocateDirect(overlay.count * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        scratch.clear(); scratch.put(overlay.verts, 0, overlay.count); scratch.position(0)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, overlayVbo)
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, overlay.count * 4, scratch, GLES20.GL_STREAM_DRAW)
        drawBuffer(overlayVbo, overlay.count / VoxelMesher.STRIDE)
    }

    private fun cube(
        mesh: ChunkMesh, x0: Float, y0: Float, z0: Float, x1: Float, y1: Float, z1: Float,
        r: Float, g: Float, b: Float,
    ) {
        mesh.quad(x0,y1,z0, x1,y1,z0, x1,y1,z1, x0,y1,z1, r, g, b)               // top
        mesh.quad(x0,y0,z1, x1,y0,z1, x1,y0,z0, x0,y0,z0, r*.6f, g*.6f, b*.6f)   // bottom
        mesh.quad(x1,y0,z0, x1,y0,z1, x1,y1,z1, x1,y1,z0, r*.8f, g*.8f, b*.8f)   // +x
        mesh.quad(x0,y0,z1, x0,y0,z0, x0,y1,z0, x0,y1,z1, r*.8f, g*.8f, b*.8f)   // -x
        mesh.quad(x1,y0,z1, x0,y0,z1, x0,y1,z1, x1,y1,z1, r*.9f, g*.9f, b*.9f)   // +z
        mesh.quad(x0,y0,z0, x1,y0,z0, x1,y1,z0, x0,y1,z0, r*.7f, g*.7f, b*.7f)   // -z
    }

    // ---- shader plumbing ----
    private fun link(vs: String, fs: String): Int {
        val v = compile(GLES20.GL_VERTEX_SHADER, vs)
        val f = compile(GLES20.GL_FRAGMENT_SHADER, fs)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, v); GLES20.glAttachShader(p, f); GLES20.glLinkProgram(p)
        val ok = IntArray(1); GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "link: " + GLES20.glGetProgramInfoLog(p) }
        return p
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type); GLES20.glShaderSource(s, src); GLES20.glCompileShader(s)
        val ok = IntArray(1); GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        check(ok[0] != 0) { "compile: " + GLES20.glGetShaderInfoLog(s) }
        return s
    }

    companion object {
        private const val MAX_REMESH_PER_FRAME = 5
        private const val SKY_R = 0.51f; private const val SKY_G = 0.77f; private const val SKY_B = 0.93f

        private const val VERT = """
            uniform mat4 uMVP; uniform vec3 uCam; uniform float uFogStart; uniform float uFogEnd;
            attribute vec3 aPos; attribute vec3 aColor;
            varying vec3 vColor; varying float vFog;
            void main() {
                gl_Position = uMVP * vec4(aPos, 1.0);
                vColor = aColor;
                float d = distance(aPos, uCam);
                vFog = clamp((d - uFogStart) / (uFogEnd - uFogStart), 0.0, 1.0);
            }
        """

        private const val FRAG = """
            precision mediump float;
            uniform vec3 uSky;
            varying vec3 vColor; varying float vFog;
            void main() { gl_FragColor = vec4(mix(vColor, uSky, vFog), 1.0); }
        """
    }
}
