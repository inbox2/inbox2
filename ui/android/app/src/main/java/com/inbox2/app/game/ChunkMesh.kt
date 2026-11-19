package com.inbox2.app.game

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * CPU-side vertex store for one chunk, with a growable backing [FloatArray] reused across
 * re-meshes (no churn in the hot path). [verts] / [count] are uploaded to a GL VBO by the
 * renderer; [dirty] flags that the GPU copy is stale.
 */
class ChunkMesh {
    var verts = FloatArray(4096)
    var count = 0           // number of floats in use
    var dirty = true        // CPU data changed → renderer must re-upload
    var glBuffer = 0        // GL VBO handle (0 = not yet created)
    var glVertexCount = 0   // vertices currently in the VBO

    private var w = 0

    fun begin(): ChunkMesh { w = 0; return this }
    fun end() { count = w; dirty = true }

    private fun ensure(extra: Int) {
        if (w + extra <= verts.size) return
        var n = verts.size
        while (n < w + extra) n = n * 2
        verts = verts.copyOf(n)
    }

    /** Append a quad (two CCW triangles) as 6 interleaved [x,y,z,r,g,b] vertices. */
    fun quad(
        ax: Float, ay: Float, az: Float,
        bx: Float, by: Float, bz: Float,
        cx: Float, cy: Float, cz: Float,
        dx: Float, dy: Float, dz: Float,
        r: Float, g: Float, b: Float,
    ) {
        ensure(6 * VoxelMesher.STRIDE)
        vert(ax, ay, az, r, g, b); vert(bx, by, bz, r, g, b); vert(cx, cy, cz, r, g, b)
        vert(ax, ay, az, r, g, b); vert(cx, cy, cz, r, g, b); vert(dx, dy, dz, r, g, b)
    }

    private fun vert(x: Float, y: Float, z: Float, r: Float, g: Float, b: Float) {
        val a = verts
        a[w] = x; a[w + 1] = y; a[w + 2] = z; a[w + 3] = r; a[w + 4] = g; a[w + 5] = b
        w += VoxelMesher.STRIDE
    }

    /** Copy the live floats into a direct buffer for glBufferData. */
    fun toDirectBuffer(scratch: FloatBuffer?): FloatBuffer {
        val needBytes = count * 4
        val buf = if (scratch != null && scratch.capacity() >= count) scratch else
            ByteBuffer.allocateDirect(maxOf(needBytes, 4096))
                .order(ByteOrder.nativeOrder()).asFloatBuffer()
        buf.clear()
        buf.put(verts, 0, count)
        buf.position(0)
        return buf
    }
}
