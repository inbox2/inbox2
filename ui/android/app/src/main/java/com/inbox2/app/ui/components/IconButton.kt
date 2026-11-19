package com.inbox2.app.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.Box
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme

/**
 * A circular, borderless icon action button — the app's most-repeated tap atom
 * (reader header actions, the bulk-bar buttons). Collapses the recurring
 * `Box(size().clip(CircleShape)[.background()].noRippleClickable){ Icon(size) }`
 * into one place so the tap target + glyph treatment stay consistent. `spinning`
 * drives the sync spinner; pass `background` for a filled chip, omit for a bare glyph.
 * (The header-row icon with leading padding stays bespoke — different layout.)
 */
@Composable
fun AeroIconButton(
    icon: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    boxSize: Dp = 40.dp,
    iconSize: Dp = 18.dp,
    tint: Color? = null,
    background: Color? = null,
    spinning: Boolean = false,
) {
    val p = theme
    val angle by if (spinning) {
        rememberInfiniteTransition(label = "spin").animateFloat(
            0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing)), label = "a",
        )
    } else remember { androidx.compose.runtime.mutableStateOf(0f) }
    Box(
        modifier
            .size(boxSize)
            // Groovebox: a filled chip is a dark keycap.
            .then(if (background != null && p.groove != null) Modifier.darkKeycap(p.groove) else Modifier)
            .clip(CircleShape)
            .then(if (background != null && p.groove == null) Modifier.background(background) else Modifier)
            .noRippleClickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            com.inbox2.app.ui.components.SfIcon.vector(icon), null,
            tint = tint ?: p.textSecondary,
            modifier = Modifier.size(iconSize).then(if (spinning) Modifier.rotate(angle) else Modifier),
        )
    }
}

/**
 * Bare header-row icon action (inbox header search / sync / bell): leading padding,
 * no circle chip — layout-wise distinct from [AeroIconButton]. `spinning` drives the
 * sync spinner; the infinite transition only runs while spinning (the branch disposes
 * it when the flag drops, so an idle header isn't animating forever).
 */
@Composable
fun HeaderIcon(icon: String, spinning: Boolean = false, tint: Color? = null, onClick: () -> Unit) {
    val p = theme
    val angle by if (spinning) {
        rememberInfiniteTransition(label = "hdr").animateFloat(
            0f, 360f, infiniteRepeatable(tween(900, easing = LinearEasing)), label = "spin",
        )
    } else remember { androidx.compose.runtime.mutableStateOf(0f) }
    Icon(
        SfIcon.vector(icon), null, tint = tint ?: p.textSecondary,
        modifier = Modifier.padding(start = Space.s3).size(22.dp)
            .then(if (spinning) Modifier.rotate(angle) else Modifier)
            .noRippleClickable(onClick = onClick),
    )
}
