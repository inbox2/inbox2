package com.inbox2.app.ui.screens

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.inbox2.app.R
import com.inbox2.app.theme.AppIconOption
import com.inbox2.app.theme.ThemePalette
import com.inbox2.app.theme.theme

/**
 * Cold-launch splash (iOS LaunchSplash): follows the selected app icon — the cube on
 * its near-black, the graffiti mural, the 8-bit sun stage, or the venn discs on white
 * — under a shared scrim and an indeterminate ring-gradient loading bar. The host
 * (MainActivity) drops it once the engine is up. The classic cube is a flat tile here
 * (iOS renders a SceneKit cube); the venn assembles with a plain scale-in.
 */
@Composable
fun LaunchSplash() {
    val ctx = LocalContext.current
    val icon = remember { AppIconOption.current(ctx) }
    // Groovebox (theme or icon): the guidebook scene draws itself in (web lib/groovebox.js), then holds.
    if (theme.groove != null || icon == AppIconOption.GROOVEBOX) {
        GrooveboxSplash(theme.groove ?: com.inbox2.app.theme.GrooveStyle()); return
    }
    val (background, onLight) = remember(icon) { launchTheme(icon) }
    var contentIn by remember { mutableStateOf(false) }
    val contentAlpha by animateFloatAsState(if (contentIn) 1f else 0f, tween(300), label = "splash-in")
    val settle by animateFloatAsState(if (contentIn) 1f else 0.7f, tween(700, easing = LinearOutSlowInEasing), label = "splash-settle")
    LaunchedEffect(Unit) { contentIn = true }

    Box(Modifier.fillMaxSize().background(background)) {
        Box(Modifier.fillMaxSize().alpha(contentAlpha), contentAlignment = Alignment.Center) {
            when (icon) {
                AppIconOption.CLASSIC -> Box(
                    Modifier.size(132.dp).scale(settle).clip(CircleShape).background(ThemePalette.unifiedLogoTile),
                    contentAlignment = Alignment.Center,
                ) { Image(painterResource(R.drawable.ch_unified), "inbox2", modifier = Modifier.size(82.dp)) }
                AppIconOption.GRAFFITI -> Image(painterResource(R.drawable.launch_graffiti), null,
                    contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                AppIconOption.SUN -> Image(painterResource(R.drawable.launch_sun), null,
                    contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                AppIconOption.GROOVEBOX -> Unit   // drawn by GrooveboxSplash above
                AppIconOption.VENNLIGHT -> Image(painterResource(R.drawable.app_icon_vennlight), "inbox2",
                    modifier = Modifier.size(160.dp).scale(settle).clip(RoundedCornerShape(36.dp)))
            }
        }
        // The scrim lets the bar stay legible over artwork, whatever the crop lands on.
        Box(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(340.dp).alpha(contentAlpha)
                .background(Brush.verticalGradient(listOf(Color.Transparent, background.copy(alpha = 0.5f), background.copy(alpha = 0.9f)))),
            contentAlignment = Alignment.BottomCenter,
        ) { LaunchLoadingBar(onLight, Modifier.padding(bottom = 74.dp).width(132.dp).height(5.dp)) }
    }
}

/** Groovebox launch: grid fades up over the first 40%, then the outlined objects appear
 *  one after another — ~1.6s, then hold (MainActivity floors the splash to match). */
@Composable
private fun GrooveboxSplash(g: com.inbox2.app.theme.GrooveStyle) {
    val run = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(Unit) { run.animateTo(1f, tween(GROOVEBOX_SPLASH_MS, easing = LinearEasing)) }
    Box(Modifier.fillMaxSize()) {
        com.inbox2.app.ui.components.GrooveboxScene(g, { run.value }, Modifier.fillMaxSize())
        LaunchLoadingBar(false, Modifier.align(Alignment.BottomCenter).padding(bottom = 74.dp).width(132.dp).height(5.dp))
    }
}

const val GROOVEBOX_SPLASH_MS = 1600

/** Per-icon splash ground (iOS LaunchTheme). `onLight` flips the bar's track. */
private fun launchTheme(icon: AppIconOption): Pair<Color, Boolean> = when (icon) {
    AppIconOption.CLASSIC -> Color(0xFF090A0E) to false
    AppIconOption.GRAFFITI -> Color(0xFF432C54) to false   // quantised from the mural
    AppIconOption.SUN -> Color(0xFFED866E) to true          // the stage's bottom band
    AppIconOption.VENNLIGHT -> Color.White to true
    AppIconOption.GROOVEBOX -> Color(0xFF2A2A2E) to false
}

/** Indeterminate sweep on a capsule track, pinned to the dark ring so it looks the
 *  same whatever theme is active (iOS LaunchLoadingBar). */
@Composable
private fun LaunchLoadingBar(onLight: Boolean, modifier: Modifier) {
    val sweep by rememberInfiniteTransition(label = "sweep").animateFloat(
        0f, 1f, infiniteRepeatable(tween(1150, easing = LinearEasing), RepeatMode.Restart), label = "sweep")
    BoxWithConstraints(
        modifier.clip(CircleShape).background(if (onLight) Color.Black.copy(alpha = 0.14f) else Color.White.copy(alpha = 0.22f)),
    ) {
        val w = maxWidth
        Box(
            Modifier.offset(x = -w * 0.45f + w * 1.45f * sweep).width(w * 0.45f).height(maxHeight)
                .background(Brush.horizontalGradient(ThemePalette.Dark.ringColors), CircleShape),
        )
    }
}
