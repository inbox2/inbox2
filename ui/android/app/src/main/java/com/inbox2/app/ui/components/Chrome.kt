package com.inbox2.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.ChannelColor
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.bevel
import com.inbox2.app.theme.scrim
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme

// The inbox tab's purple accent — the default for floating affordances over the inbox.
val InboxAccent = listOf(ChannelColor.violet, ChannelColor.violetDeep)

/**
 * The shared floating-capsule chrome (iOS GlowCapsule): a solid elevated capsule, one
 * hairline and one soft shadow. One source for the bottom nav, the bulk-action bar, and
 * the undo/send toasts so they read as one family. `colors` tints the hairline where the
 * accent carries meaning (the toasts signal their action by hue); pass an empty list for
 * a plain neutral edge, as the nav does.
 */
@Composable
fun Modifier.glowCapsule(colors: List<Color> = InboxAccent): Modifier {
    val p = theme
    val capsule: Shape = RoundedCornerShape(Radius.full)
    val edge: Brush =
        if (colors.isEmpty()) SolidColor(if (p.isDark) bevel(0.09f) else scrim(0.12f))
        else Brush.horizontalGradient(colors.map { it.copy(alpha = 0.55f) })
    return this
        .shadow(if (p.isDark) 14.dp else 10.dp, capsule, clip = false)
        .background(p.floatFill ?: if (p.isDark) p.bgElevated else Color.White, capsule)
        .border(1.dp, edge, capsule)
        .clip(capsule)
}

/**
 * Groovebox keycap: a [face] over a hard [edge] that shows [depth] below it, with an
 * optional 1dp top [highlight] (web --btn-shadow `0 2px 0` + `inset 0 1px 0`). Drawn
 * inside the bounds (the face is `depth` short) so clipping parents can't cut the edge.
 * `face` gets the face size, for radial domes.
 */
fun Modifier.keycap(
    face: (androidx.compose.ui.geometry.Size) -> Brush,
    edge: Color,
    depth: androidx.compose.ui.unit.Dp,
    radius: androidx.compose.ui.unit.Dp = Radius.full,
    highlight: Color? = null,
): Modifier = drawBehind {
    val d = depth.toPx()
    val faceSize = androidx.compose.ui.geometry.Size(size.width, size.height - d)
    val r = androidx.compose.ui.geometry.CornerRadius(minOf(radius.toPx(), faceSize.height / 2, size.width / 2))
    drawRoundRect(edge, topLeft = androidx.compose.ui.geometry.Offset(0f, d), size = faceSize, cornerRadius = r)
    if (highlight != null) {
        drawRoundRect(highlight, size = faceSize, cornerRadius = r)
        val h = 1.dp.toPx()
        drawRoundRect(face(faceSize), topLeft = androidx.compose.ui.geometry.Offset(0f, h),
            size = androidx.compose.ui.geometry.Size(faceSize.width, faceSize.height - h), cornerRadius = r)
    } else drawRoundRect(face(faceSize), size = faceSize, cornerRadius = r)
}

/** A solid pastel chip on a 2dp dark bottom shadow (Groovebox labels/tags). Pad the
 *  content 2dp more at the bottom for the shadow. */
fun Modifier.pastelChip(color: Color, g: com.inbox2.app.theme.GrooveStyle, radius: androidx.compose.ui.unit.Dp = 6.dp) =
    keycap({ SolidColor(color) }, g.chipShadow, 2.dp, radius)

/** Groovebox: frame a content block on a solid #121214 panel (20dp, inset 12dp from the
 *  screen edges) so the guidebook grid only shows in the gutters. No-op elsewhere. */
@Composable
fun Modifier.groovePanel(): Modifier {
    val p = theme
    return if (p.groove != null) padding(horizontal = Space.s3).clip(RoundedCornerShape(Radius.xl)).background(p.bgPanel) else this
}

/** Material Switch colours: the default (accent) look, teal checked under Groovebox. */
@Composable
fun inboxSwitchColors(): androidx.compose.material3.SwitchColors {
    val p = theme
    return if (p.groove != null) androidx.compose.material3.SwitchDefaults.colors(
        checkedThumbColor = p.bgPanel, checkedTrackColor = p.accentSuccess, checkedBorderColor = p.accentSuccess,
        uncheckedThumbColor = p.textTertiary, uncheckedTrackColor = p.bgInput, uncheckedBorderColor = p.borderStrong,
    ) else androidx.compose.material3.SwitchDefaults.colors()
}

/** The cream keycap of a selected tab (Groovebox). */
fun Modifier.creamKeycap(g: com.inbox2.app.theme.GrooveStyle, radius: androidx.compose.ui.unit.Dp = Radius.full) =
    keycap({ Brush.verticalGradient(g.creamKey) }, g.creamEdge, 3.dp, radius, Color.White)

/** A dark keycap (Groovebox secondary button). */
fun Modifier.darkKeycap(g: com.inbox2.app.theme.GrooveStyle, radius: androidx.compose.ui.unit.Dp = Radius.full) =
    keycap({ Brush.verticalGradient(g.darkKey) }, g.darkEdge, 2.dp, radius, g.keyHighlight)

/** The lavender dome of the primary action (Groovebox), lit at 38%/28% like web. */
fun Modifier.domeKeycap(g: com.inbox2.app.theme.GrooveStyle, radius: androidx.compose.ui.unit.Dp = Radius.full) =
    keycap({ s ->
        Brush.radialGradient(
            0f to g.dome[0], 0.55f to g.dome[1], 1f to g.dome[2],
            center = androidx.compose.ui.geometry.Offset(s.width * 0.38f, s.height * 0.28f),
            radius = maxOf(s.width, s.height) * 0.75f,
        )
    }, g.domeEdge, 2.dp, radius, g.domeHighlight)

/**
 * Inset "card" surface (iOS InsetCard): a raised surface with a faint gradient border
 * brightest along the top edge. Used by reader panes, AI summary, calendar, rows.
 * Applies the shared 4dp horizontal inset itself.
 */
@Composable
fun Modifier.insetCard(radius: Int = 18): Modifier {
    val p = theme
    // Groovebox: a solid black island, 20dp corners, a faint 5% edge — no bevel glass.
    p.groove?.let {
        val shape = RoundedCornerShape(Radius.xl)
        return this.padding(horizontal = 4.dp).background(p.bgSurface, shape)
            .border(1.dp, bevel(0.05f), shape).clip(shape)
    }
    val shape = RoundedCornerShape(radius.dp)
    return this
        .padding(horizontal = 4.dp)
        .background(p.bgSurface, shape)
        .border(
            1.dp,
            Brush.verticalGradient(
                0f to bevel(0.22f),
                0.10f to p.borderSubtle,
                1f to p.borderSubtle,
            ),
            shape,
        )
        .clip(shape)
}

/**
 * Frosted "Aero glass" dropdown (iOS menu material): a translucent elevated fill, a
 * bevel-gradient hairline border brightest along the top edge, rounded corners and a soft
 * shadow — so action menus and tap-&-hold menus read as glass instead of a flat slab.
 * Compose has no live backdrop blur, so the translucency + bevel approximate it (same
 * trade-off as [glowCapsule]/[insetCard]).
 */
@Composable
fun GlassDropdownMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    offset: androidx.compose.ui.unit.DpOffset = androidx.compose.ui.unit.DpOffset(0.dp, 0.dp),
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    val p = theme
    androidx.compose.material3.DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        // A comfortable min width so menus don't render as thin slivers (iOS menus).
        modifier = modifier.widthIn(min = 232.dp),
        offset = offset,
        shape = RoundedCornerShape(14.dp),
        containerColor = (if (p.isDark) p.bgElevated else p.bgRaised).copy(alpha = 0.88f),
        tonalElevation = 0.dp,
        shadowElevation = 20.dp,
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            Brush.verticalGradient(0f to bevel(0.26f), 0.14f to p.borderSubtle, 1f to p.borderSubtle),
        ),
        content = content,
    )
}

@Composable
private fun noRippleSource() = remember { MutableInteractionSource() }

/** Pill-style filter tabs (active = elevated pill with a violet edge). */
@Composable
fun FilterPills(options: List<String>, selection: String, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val p = theme
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
        options.forEach { opt ->
            val active = opt == selection
            Text(
                opt,
                style = AppFont.ui(13, if (active) FontWeight.SemiBold else FontWeight.Medium),
                color = if (active) p.groove?.creamInk ?: p.textPrimary else p.textTertiary,
                modifier = Modifier
                    .then(if (active && p.groove != null) Modifier.creamKeycap(p.groove) else Modifier)
                    .clip(RoundedCornerShape(Radius.full))
                    .then(if (active && p.groove == null) Modifier.background(p.bgElevated) else Modifier)
                    .then(if (active && p.groove == null) Modifier.border(1.dp, p.accentViolet.copy(alpha = 0.55f), RoundedCornerShape(Radius.full)) else Modifier)
                    .clickable(interactionSource = noRippleSource(), indication = null) { onSelect(opt) }
                    .padding(horizontal = Space.s3, vertical = Space.s2)
                    .then(if (active && p.groove != null) Modifier.padding(bottom = 3.dp) else Modifier),
            )
        }
    }
}

/** Enclosed segmented tab bar (iOS SegmentedTabs) — active segment is a raised capsule
 *  with a plain hairline; no accent ring, no violet cast. */
@Composable
fun SegmentedTabs(options: List<String>, selection: String, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val p = theme
    Row(
        modifier
            .clip(RoundedCornerShape(Radius.full))
            .background(if (p.groove != null) p.bgInput else p.bgBase.copy(alpha = 0.6f))
            .border(1.dp, p.borderDefault, RoundedCornerShape(Radius.full))
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(Space.s1),
    ) {
        options.forEach { opt ->
            val active = opt == selection
            Box(
                Modifier
                    .weight(1f)
                    .then(if (active && p.groove != null) Modifier.creamKeycap(p.groove) else Modifier)
                    .clip(RoundedCornerShape(Radius.full))
                    .then(
                        if (active && p.groove == null) Modifier
                            .background(p.bgRaised)
                            .border(1.dp, p.borderStrong, RoundedCornerShape(Radius.full))
                        else Modifier
                    )
                    .clickable(interactionSource = noRippleSource(), indication = null) { onSelect(opt) }
                    .padding(vertical = Space.s2 + 1.dp)
                    .then(if (active && p.groove != null) Modifier.padding(bottom = 3.dp) else Modifier),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    opt,
                    style = AppFont.ui(14, if (active) FontWeight.Bold else FontWeight.Medium),
                    color = if (active) p.groove?.creamInk ?: p.textPrimary else p.textTertiary,
                )
            }
        }
    }
}
