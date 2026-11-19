package com.inbox2.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme

/**
 * An SF-mapped glyph painted in the brand ring gradient with a soft neon halo — the
 * shared empty/zero-state hero (iOS GradientGlyph). No baked background, so it floats
 * cleanly in *both* dark and light; the old `es_*` raster art baked the `#090a0e` base,
 * which read as a dark tile in light mode.
 */
@Composable
fun GradientGlyph(systemImage: String, size: Dp = 72.dp, modifier: Modifier = Modifier) {
    val p = theme
    val brush = Brush.linearGradient(p.ringColors)
    val glow = (p.ringColors.getOrNull(1) ?: p.accentViolet).copy(alpha = 0.35f)
    Box(modifier, contentAlignment = Alignment.Center) {
        // Soft neon glow: a blurred copy behind the crisp glyph (no-ops < API 31, which
        // simply drops the halo — the gradient glyph itself still reads on any surface).
        Icon(
            SfIcon.vector(systemImage), null, tint = glow,
            modifier = Modifier.size(size).blur(size * 0.25f, BlurredEdgeTreatment.Unbounded),
        )
        // Crisp gradient-filled glyph: paint the vector solid, then tint its opaque pixels
        // with the ring gradient via SrcAtop (Icon's own tint is a single color only).
        Icon(
            SfIcon.vector(systemImage), null, tint = Color.White,
            modifier = Modifier
                .size(size)
                .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
                .drawWithContent {
                    drawContent()
                    drawRect(brush, blendMode = BlendMode.SrcAtop)
                },
        )
    }
}

/**
 * Reusable empty/zero-state (iOS EmptyState) — a themed gradient-glyph hero, a title, and
 * an optional message.
 */
@Composable
fun EmptyState(icon: String, title: String, message: String? = null, modifier: Modifier = Modifier, heroSize: Int = 72) {
    val p = theme
    Column(
        modifier.fillMaxWidth().padding(Space.s6),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.s3),
    ) {
        GradientGlyph(icon, size = heroSize.dp, modifier = Modifier.padding(bottom = Space.s2))
        Text(title, color = p.textPrimary, style = AppFont.title2, textAlign = TextAlign.Center)
        message?.let { Text(it, color = p.textTertiary, style = AppFont.sm, textAlign = TextAlign.Center) }
    }
}
