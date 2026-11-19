package com.inbox2.app.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.inbox2.app.theme.theme

/**
 * A 1dp animated brand-gradient hairline — the ambient "AI is working" cue
 * (iOS ProcessingHairline). Shown along the bottom of the inbox list while the
 * triage worker's queue is non-empty, and under the reader header while THIS
 * thread's summaries are stale. Purely decorative.
 */
@Composable
fun ProcessingHairline(modifier: Modifier = Modifier) {
    val p = theme
    val transition = rememberInfiniteTransition(label = "hairline")
    val sweep by transition.animateFloat(
        0f, 1f,
        infiniteRepeatable(tween(1400, easing = LinearEasing)),
        label = "sweep",
    )
    BoxWithConstraints(
        modifier.fillMaxWidth().height(1.dp).background(p.accentViolet.copy(alpha = 0.18f)),
    ) {
        val band = if (maxWidth * 0.35f > 80.dp) maxWidth * 0.35f else 80.dp
        Box(
            Modifier
                .width(band)
                .fillMaxHeight()
                .offset(x = -band + (maxWidth + band) * sweep)
                .background(
                    Brush.horizontalGradient(
                        listOf(Color.Transparent) + p.ringColors + listOf(Color.Transparent),
                    ),
                ),
        )
    }
}
