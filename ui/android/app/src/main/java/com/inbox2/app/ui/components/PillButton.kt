package com.inbox2.app.ui.components

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme

/**
 * The full-width rounded accent-violet action button (Connect / Save / Sign in),
 * previously hand-rolled at half a dozen call sites. `enabled = false` dims to the
 * input background (the AddAccount "Connect" treatment) and drops the click;
 * `busy = true` keeps the accent look (the label says "Saving…" etc.) but ignores
 * taps so an in-flight submit can't be double-fired.
 */
@Composable
fun PillButton(
    label: String,
    modifier: Modifier = Modifier,
    busy: Boolean = false,
    enabled: Boolean = true,
    /** Hug the label (dialog buttons, inline actions) instead of filling the width. */
    compact: Boolean = false,
    /** Fill colour override (danger for a destructive confirm, a neutral raised fill,
     *  `Color.Transparent` for a text-only button); null = the accent. */
    tint: Color? = null,
    /** Label/icon colour override; null = the accent's own label colour. */
    contentColor: Color? = null,
    /** Leading SF-symbol name. */
    icon: String? = null,
    /** Leading full-colour drawable (a brand logo); wins over [icon]. */
    @DrawableRes logo: Int? = null,
    onClick: () -> Unit,
) {
    val p = theme
    val accent = tint == null
    val fill = when {
        !enabled -> p.bgInput
        else -> tint ?: p.accentViolet
    }
    val ink = contentColor ?: p.onAccent
    Row(
        modifier.then(if (compact) Modifier.defaultMinSize(minHeight = 40.dp) else Modifier.fillMaxWidth())
            // Groovebox: the lavender dome with its hard edge instead of a flat fill.
            .then(if (enabled && accent && p.groove != null) Modifier.domeKeycap(p.groove) else Modifier)
            .clip(RoundedCornerShape(Radius.full))
            .then(if (enabled && accent && p.groove != null) Modifier else Modifier.background(fill))
            .noRippleClickable(enabled = enabled && !busy, onClick = onClick)
            .then(if (compact) Modifier.padding(horizontal = Space.s3, vertical = Space.s2) else Modifier.padding(vertical = Space.s3)),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (logo != null) {
            Image(painterResource(logo), null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(5.dp))
        } else if (icon != null) {
            Icon(SfIcon.vector(icon), null, tint = ink, modifier = Modifier.size(15.dp))
            Spacer(Modifier.width(5.dp))
        }
        Text(label, color = ink, style = if (compact) AppFont.sm else AppFont.md, fontWeight = if (compact) FontWeight.SemiBold else null)
    }
}

/** The dialog "text button" role (Cancel / OK / Keep editing): a compact, transparent
 *  pill in the accent colour, so dialogs share the one button atom. */
@Composable
fun PillTextButton(label: String, enabled: Boolean = true, onClick: () -> Unit) {
    val p = theme
    PillButton(label, compact = true, enabled = enabled, tint = Color.Transparent,
        contentColor = if (enabled) p.accentViolet else p.textTertiary, onClick = onClick)
}
