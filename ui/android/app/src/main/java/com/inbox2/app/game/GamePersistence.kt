package com.inbox2.app.game

import android.content.Context

/** Small resume blob (no live voxels) — current level/score + best level reached. */
object GamePersistence {
    private const val PREFS = "voxelstrike"
    data class Snapshot(val level: Int, val score: Int, val best: Int, val hasRun: Boolean)

    fun load(ctx: Context): Snapshot {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return Snapshot(
            level = p.getInt("level", 1),
            score = p.getInt("score", 0),
            best = p.getInt("best", 0),
            hasRun = p.contains("level"),
        )
    }

    fun save(ctx: Context, level: Int, score: Int) {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        p.edit()
            .putInt("level", level)
            .putInt("score", score)
            .putInt("best", maxOf(p.getInt("best", 0), level))
            .apply()
    }

    fun clear(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
    }
}
