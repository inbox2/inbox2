package com.inbox2.app.ui.components

import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme

data class NavItem(val icon: String, val label: String)

/**
 * Floating capsule bottom nav (iOS FloatingNavBar): a flat pill holding five equal
 * actions — the four tabs plus Compose sitting in the middle as a peer, same chip,
 * same size. The selected tab is a solid violet pill that widens to carry its label;
 * everything else is a dimmed chip. No halo, no gradient border, no per-tab
 * recolouring of the bar: violet here means exactly one thing, "selected".
 */
@Composable
fun FloatingNavBar(selection: Int, items: List<NavItem>, onSelect: (Int) -> Unit, onCompose: () -> Unit) {
    val mid = items.size / 2
    Row(
        Modifier
            .glowCapsule(emptyList())
            .padding(horizontal = Space.s1 + 2.dp, vertical = Space.s1 + 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s1),
    ) {
        // Groovebox rainbow tabs: each slot (Compose included) owns a colour, in bar order.
        val tabs = theme.groove?.navTabs
        items.forEachIndexed { i, item ->
            if (i == mid) ComposeButton(onCompose)
            NavButton(i, item, selection, onSelect, tabs?.getOrNull(if (i < mid) i else i + 1))
        }
    }
}

@Composable
private fun RowScope.NavButton(idx: Int, item: NavItem, selection: Int, onSelect: (Int) -> Unit, tabColor: Color? = null) {
    val p = theme
    val active = idx == selection
    val shape = RoundedCornerShape(Radius.full)
    Row(
        Modifier
            .height(48.dp)
            .widthIn(min = 48.dp)
            .animateContentSize(spring(dampingRatio = 0.86f, stiffness = Spring.StiffnessMediumLow))
            // Groovebox: the selected tab is a cream keycap (drawn in-bounds, so the
            // clip below keeps its hard bottom edge).
            // Rainbow tabs: the selected one is a dark keycap; only its icon carries the colour.
            .then(if (active && p.groove != null) (if (tabColor != null) Modifier.darkKeycap(p.groove) else Modifier.creamKeycap(p.groove)) else Modifier)
            .clip(shape)
            .then(if (active && p.groove == null) Modifier.background(p.accentViolet) else Modifier)
            .noRippleClickable { onSelect(idx) }
            .padding(horizontal = if (active) Space.s4 - 2.dp else 0.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s2 - 1.dp, Alignment.CenterHorizontally),
    ) {
        // Idle chips sit on a dimmed textSecondary, so the lit violet pill is the only
        // thing on the bar carrying full contrast.
        Icon(
            SfIcon.vector(item.icon), item.label,
            // More ink on unselected items in light themes (iOS Nav 0.78).
            tint = if (active) tabColor ?: p.groove?.creamInk ?: p.onAccent else p.textSecondary.copy(alpha = if (p.isDark) 0.55f else 0.78f),
            modifier = Modifier.size(23.dp),
        )
        if (active) {
            Text(
                item.label, color = if (tabColor != null) p.textPrimary else p.groove?.creamInk ?: p.onAccent, style = AppFont.ui(14, FontWeight.SemiBold),
                maxLines = 1, overflow = TextOverflow.Clip, softWrap = false,
            )
        }
    }
}

/**
 * Compose is an action, not a tab: it never takes the violet pill, so it renders as a
 * permanently-idle chip identical to the unselected tabs.
 */
@Composable
private fun ComposeButton(onCompose: () -> Unit) {
    val p = theme
    Box(
        Modifier.size(48.dp).clip(CircleShape).noRippleClickable { onCompose() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            SfIcon.vector("square.and.pencil"), "Compose",
            tint = p.textSecondary.copy(alpha = if (p.isDark) 0.55f else 0.78f), modifier = Modifier.size(23.dp),
        )
    }
}

/**
 * Big screen header (iOS ScreenHeader): a large small-caps title in the softer
 * secondary gray, an optional leading back chevron, an optional leading slot
 * (top-left actions, e.g. the Bridge car-mode toggle), and an optional trailing slot.
 */
@Composable
fun ScreenHeader(
    title: String,
    showBack: Boolean = false,
    onBack: () -> Unit = {},
    /** Screen titles are uppercase; the reader passes false (iOS shows the subject as-is). */
    uppercase: Boolean = true,
    leading: @Composable RowScope.() -> Unit = {},
    trailing: @Composable RowScope.() -> Unit = {},
) {
    val p = theme
    Row(
        Modifier.padding(horizontal = Space.s4, vertical = Space.s2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s2 + 2.dp),
    ) {
        if (showBack) {
            Icon(
                SfIcon.vector("chevron.left"), "Back", tint = p.textSecondary,
                modifier = Modifier.size(22.dp).noRippleClickable { onBack() },
            )
        }
        leading()
        // Weighted box so a long title truncates instead of squeezing the
        // trailing actions out of the row (iOS truncates and keeps both icons).
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            Text(
                if (uppercase) title.uppercase() else title, color = p.textSecondary, style = AppFont.title,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        trailing()
    }
}
