package com.inbox2.app.game

import android.content.Context
import android.opengl.GLSurfaceView

/** Minimal GLES2 surface hosting the [VoxelRenderer]; input is handled by the Compose layer. */
class GameSurfaceView(context: Context, val game: VoxelGame) : GLSurfaceView(context) {
    val renderer = VoxelRenderer(game)
    init {
        setEGLContextClientVersion(2)
        // Translucent not needed — the world fills the frame; keep an opaque RGB surface.
        setRenderer(renderer)
        renderMode = RENDERMODE_CONTINUOUSLY
    }
}
