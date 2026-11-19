package com.inbox2.app.game

import android.content.Context
import android.graphics.BitmapFactory
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/** Decoded weapon/egg sprites (Higgsfield art under assets/game/). */
class GameArt(ctx: Context) {
    val weapons: Map<Weapon, ImageBitmap> = Weapon.ordered.associateWith { decode(ctx, it.asset) }
    val egg: ImageBitmap = decode(ctx, "game/egg.png")
    private fun decode(ctx: Context, path: String): ImageBitmap =
        ctx.assets.open(path).use { BitmapFactory.decodeStream(it) }.asImageBitmap()
}

/**
 * VOXEL STRIKE — full-screen game overlay. Hosts the GLES [GameSurfaceView] and layers the
 * HUD, touch controls, and start / level-complete panels on top. Mirrors the iOS NEON STRIKE
 * presentation: a self-contained overlay launched from the Bridge screen, resume to prefs.
 */
@Composable
fun VoxelStrikeScreen(onClose: () -> Unit) {
    val ctx = LocalContext.current
    val game = remember { VoxelGame() }
    val art = remember { GameArt(ctx) }
    val saved = remember { GamePersistence.load(ctx) }
    val surface = remember { GameSurfaceView(ctx, game) }
    val hud = game.hud

    BackHandler(enabled = true) { onClose() }

    DisposableEffect(Unit) {
        onDispose {
            surface.onPause()
            GamePersistence.save(ctx, game.level, hud.score)
            game.dispose()
        }
    }

    Box(Modifier.fillMaxSize().background(Color(0xFF0B0F14))) {
        AndroidView(factory = { surface }, modifier = Modifier.fillMaxSize())

        when (hud.status) {
            GameStatus.PLAYING -> GameControls(game, art, hud, onClose)
            GameStatus.START -> StartPanel(saved, onNew = { game.newGame() },
                onContinue = { game.continueFrom(saved.level, saved.score) }, onClose = onClose)
            GameStatus.LEVEL_COMPLETE -> LevelCompletePanel(hud, art) { game.nextLevel() }
        }
    }
}

@Composable
private fun StartPanel(
    saved: GamePersistence.Snapshot,
    onNew: () -> Unit,
    onContinue: () -> Unit,
    onClose: () -> Unit,
) {
    Box(Modifier.fillMaxSize().background(Color(0xCC0B0F14)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            GameTitle("VOXEL STRIKE")
            GameLabel("Dig out the golden egg. Blow the world apart to find it.")
            if (saved.best > 0) GameLabel("Best: reached level ${saved.best}")
            GameButton(if (saved.hasRun) "CONTINUE · LEVEL ${saved.level}" else "DROP IN", primary = true,
                onClick = onContinue.takeIf { saved.hasRun } ?: onNew)
            if (saved.hasRun) GameButton("NEW GAME", primary = false, onClick = onNew)
            GameButton("CLOSE", primary = false, onClick = onClose)
        }
    }
}

@Composable
private fun LevelCompletePanel(hud: Hud, art: GameArt, onNext: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color(0xCC0B0F14)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Image(art.egg, contentDescription = "Golden egg",
                modifier = Modifier.size(120.dp).padding(bottom = 4.dp))
            GameTitle("EGG SECURED")
            GameLabel("Level ${hud.level} cleared · Score ${hud.score}")
            GameLabel("Next world: ${Biomes.forLevel(hud.level + 1).name}")
            GameButton("NEXT LEVEL", primary = true, onClick = onNext)
        }
    }
}
