package com.inbox2.app.game

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.hypot
import kotlin.math.min

private val Ink = Color(0xFF0B0F14)
private val Panel = Color(0xE61A2230)
private val Edge = Color(0x33FFFFFF)
private val Gold = Color(0xFFFFD23F)
private val Cold = Color(0xFF3D8BFF)

@Composable
fun GameControls(game: VoxelGame, art: GameArt, hud: Hud, onClose: () -> Unit) {
    val sens = 0.0042f
    // Look — drag anywhere not covered by a control.
    Box(Modifier.fillMaxSize().pointerInput(Unit) {
        detectDragGestures { change, drag -> change.consume(); game.addLook(drag.x * sens, drag.y * sens) }
    })

    // Crosshair
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(22.dp)) {
            val c = size.minDimension / 2f
            drawLine(Color(0xCCFFFFFF), Offset(c - 9, c), Offset(c + 9, c), 2.5f)
            drawLine(Color(0xCCFFFFFF), Offset(c, c - 9), Offset(c, c + 9), 2.5f)
        }
    }

    Column(Modifier.fillMaxSize().padding(14.dp)) {
        // Top bar
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column {
                Text("LEVEL ${hud.level}", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                Text(hud.biome.ifEmpty { "SCORE ${hud.score}" }, color = Gold, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                Text("SCORE ${hud.score}", color = Color(0xFFB8C2CF), fontSize = 12.sp)
            }
            Spacer(Modifier.width(16.dp))
            EggHint(hud.eggHint, hud.eggExposed, Modifier.weight(1f))
            Spacer(Modifier.width(16.dp))
            Box(Modifier.size(34.dp).background(Panel, CircleShape).border(1.dp, Edge, CircleShape)
                .clickable { onClose() }, contentAlignment = Alignment.Center) {
                Text("✕", color = Color.White, fontSize = 16.sp)
            }
        }

        Spacer(Modifier.height(10.dp))
        WeaponSelector(game, art, hud)
        Spacer(Modifier.weight(1f))

        // Equipped weapon art (decorative, bottom-center) + name
        val selected = Weapon.ordered[hud.weaponIndex]
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Image(art.weapons[selected]!!, contentDescription = selected.label,
                modifier = Modifier.size(132.dp))
        }
    }

    // Bottom controls overlaid (own pointer regions so they win over the look layer).
    Box(Modifier.fillMaxSize().padding(18.dp)) {
        MoveJoystick(game, Modifier.align(Alignment.BottomStart))
        Column(Modifier.align(Alignment.BottomEnd), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                HoldButton("▲", 56.dp, Cold) { game.setFloating(it) }
                HoldButton("▼", 56.dp, Color(0xFF8A6A3A)) { game.setSinking(it) }
            }
            HoldButton("FIRE", 92.dp, Color(0xFFE0492F)) { game.setFire(it) }
        }
    }
}

@Composable
private fun EggHint(hint: Float, exposed: Boolean, modifier: Modifier) {
    val heat = 1f - hint
    val fill = lerp(Cold, Gold, heat)
    Column(modifier) {
        Text(if (exposed) "EGG IN SIGHT" else "EGG PROXIMITY",
            color = if (exposed) Gold else Color(0xFFB8C2CF), fontSize = 11.sp, fontWeight = FontWeight.Bold)
        Box(Modifier.fillMaxWidth().height(8.dp).padding(top = 3.dp)
            .background(Color(0x33000000), RoundedCornerShape(4.dp))) {
            Box(Modifier.fillMaxWidth(min(1f, 0.06f + heat)).height(8.dp)
                .background(fill, RoundedCornerShape(4.dp)))
        }
    }
}

@Composable
private fun WeaponSelector(game: VoxelGame, art: GameArt, hud: Hud) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Weapon.ordered.forEach { w ->
            val on = hud.weaponIndex == w.ordinal
            Box(
                Modifier.size(54.dp)
                    .background(if (on) Color(0xFF243247) else Panel, RoundedCornerShape(10.dp))
                    .border(if (on) 2.dp else 1.dp, if (on) Gold else Edge, RoundedCornerShape(10.dp))
                    .clickable { game.selectWeapon(w) }
                    .padding(5.dp),
                contentAlignment = Alignment.Center,
            ) { Image(art.weapons[w]!!, contentDescription = w.label, modifier = Modifier.fillMaxSize()) }
        }
    }
}

@Composable
private fun MoveJoystick(game: VoxelGame, modifier: Modifier) {
    val radiusDp = 62.dp
    val radiusPx = with(LocalDensity.current) { radiusDp.toPx() }
    var knob by remember { mutableStateOf(Offset.Zero) }
    Box(
        modifier.size(radiusDp * 2).background(Color(0x33121A26), CircleShape)
            .border(1.dp, Edge, CircleShape)
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = {}, onDragCancel = { knob = Offset.Zero; game.setMove(0f, 0f) },
                    onDragEnd = { knob = Offset.Zero; game.setMove(0f, 0f) },
                ) { change, drag ->
                    change.consume()
                    var o = knob + drag
                    val len = hypot(o.x, o.y)
                    if (len > radiusPx) o *= (radiusPx / len)
                    knob = o
                    game.setMove(o.x / radiusPx, -o.y / radiusPx)
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.offset { IntOffset(knob.x.toInt(), knob.y.toInt()) }.size(50.dp)
            .background(Color(0xCC2E3C52), CircleShape).border(1.dp, Edge, CircleShape))
    }
}

@Composable
private fun HoldButton(label: String, size: androidx.compose.ui.unit.Dp, tint: Color, onHold: (Boolean) -> Unit) {
    Box(
        Modifier.size(size).background(tint.copy(alpha = 0.92f), CircleShape)
            .border(1.5.dp, Color(0x55FFFFFF), CircleShape)
            .pointerInput(Unit) {
                detectTapGestures(onPress = { onHold(true); tryAwaitRelease(); onHold(false) })
            },
        contentAlignment = Alignment.Center,
    ) { Text(label, color = Color.White, fontWeight = FontWeight.Bold, fontSize = if (label.length > 2) 16.sp else 22.sp) }
}

// ---- shared start/level widgets ----
@Composable
fun GameTitle(text: String) =
    Text(text, color = Gold, fontWeight = FontWeight.Black, fontSize = 34.sp)

@Composable
fun GameLabel(text: String) =
    Text(text, color = Color(0xFFC4CEDA), fontSize = 14.sp)

@Composable
fun GameButton(text: String, primary: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.width(260.dp).height(50.dp)
            .background(if (primary) Color(0xFFE0492F) else Panel, RoundedCornerShape(12.dp))
            .border(1.dp, if (primary) Color(0x66FFFFFF) else Edge, RoundedCornerShape(12.dp))
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) { Text(text, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp) }
}
