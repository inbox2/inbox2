package com.inbox2.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.ThemePalette
import com.inbox2.app.theme.theme

/** Pill badge with a dim accent fill (iOS InboxTag). */
@Composable
fun InboxTag(text: String, color: Color, modifier: Modifier = Modifier) {
    val g = theme.groove
    Text(
        text,
        style = AppFont.ui(10, FontWeight.SemiBold),
        color = g?.chipInk ?: color,
        modifier = modifier
            .chipFill(color, 0.16f, g)
            .padding(horizontal = 7.dp, vertical = 2.dp)
            .then(if (g != null) Modifier.padding(bottom = 2.dp) else Modifier),
    )
}

/** Dim accent pill — or, under Groovebox, a solid pastel chip (radius 6) on a 2dp dark
 *  bottom shadow. */
private fun Modifier.chipFill(color: Color, alpha: Float, g: com.inbox2.app.theme.GrooveStyle?) =
    if (g == null) background(color.copy(alpha = alpha), RoundedCornerShape(Radius.full))
    else pastelChip(color, g)

/** AI classification chip: icon + label, dim accent fill (iOS AIBadge). */
@Composable
fun AIBadge(label: String, icon: String, color: Color, modifier: Modifier = Modifier) {
    val g = theme.groove
    val ink = g?.chipInk ?: color
    Row(
        modifier
            .chipFill(color, 0.14f, g)
            .padding(horizontal = 7.dp, vertical = 2.dp)
            .then(if (g != null) Modifier.padding(bottom = 2.dp) else Modifier),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(SfIcon.vector(icon), null, tint = ink, modifier = Modifier.size(11.dp))
        Spacer(Modifier.width(3.dp))
        Text(label, style = AppFont.ui(11, FontWeight.Medium), color = ink)
    }
}

/** Sentiment badge (iOS AIBadge.sentiment): positive = smile/success, negative = dashed/danger. */
@Composable
fun SentimentBadge(positive: Boolean, modifier: Modifier = Modifier) {
    val p = theme
    if (positive) AIBadge("Positive", "face.smiling", p.accentSuccess, modifier)
    else AIBadge("Negative", "face.dashed", p.accentDanger, modifier)
}

/** Intent badge (iOS AIBadge.intent): per-kind icon + palette color. */
@Composable
fun IntentBadge(kind: com.inbox2.app.model.IntentKind, modifier: Modifier = Modifier) {
    val p = theme
    val color = when (kind) {
        com.inbox2.app.model.IntentKind.QUESTION -> p.accentAmber
        com.inbox2.app.model.IntentKind.REQUEST -> p.accentPurple
        com.inbox2.app.model.IntentKind.COMPLAINT -> p.accentDanger
        com.inbox2.app.model.IntentKind.SCHEDULING -> p.accentTeal
        com.inbox2.app.model.IntentKind.FYI -> p.accentPrimary
    }
    AIBadge(kind.label, kind.sfIcon, color, modifier)
}
