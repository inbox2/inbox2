package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Appearance
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.ThemeManager
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.AIBadge
import com.inbox2.app.ui.components.AvatarRing
import com.inbox2.app.ui.components.InboxTag
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SegmentedTabs
import com.inbox2.app.ui.components.insetCard

/** The component / style guide — the approval surface (iOS StyleGuideView, dev-only):
 *  the ported tokens and primitives with a live appearance switch. */
@Composable
fun StyleGuideScreen(themeManager: ThemeManager, onBack: () -> Unit) {
    val p = theme
    var sample by remember { mutableStateOf("billing@acme.com") }
    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader("Style guide", showBack = true, onBack = onBack)
        Column(Modifier.padding(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s6)) {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                Text("INBOX2 STYLE GUIDE", color = p.textTertiary, style = AppFont.xs3)
                SegmentedTabs(Appearance.entries.map { it.title }, themeManager.appearance.title,
                    { sel -> Appearance.entries.first { it.title == sel }.let(themeManager::set) })
            }

            Section("Colors") {
                val swatches = listOf(
                    "bgBase" to p.bgBase, "bgPanel" to p.bgPanel, "bgSurface" to p.bgSurface, "bgElevated" to p.bgElevated,
                    "bgInput" to p.bgInput, "textPrimary" to p.textPrimary, "textSecondary" to p.textSecondary,
                    "textTertiary" to p.textTertiary, "accentViolet" to p.accentViolet, "accentPrimary" to p.accentPrimary,
                    "accentWarm" to p.accentWarm, "accentSuccess" to p.accentSuccess, "accentDanger" to p.accentDanger,
                    "accentAmber" to p.accentAmber, "accentTeal" to p.accentTeal, "accentPurple" to p.accentPurple,
                )
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(Space.s2)) {
                    swatches.forEach { (name, c) ->
                        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Space.s1)) {
                            Box(Modifier.size(44.dp).clip(RoundedCornerShape(Radius.lg)).background(c)
                                .padding(1.dp).clip(RoundedCornerShape(Radius.lg)).background(c))
                            Text(name, color = p.textTertiary, style = AppFont.ui(9))
                        }
                    }
                }
            }

            Section("Typography") {
                listOf("display" to AppFont.display, "title" to AppFont.title, "title2" to AppFont.title2, "title3" to AppFont.title3,
                    "xl" to AppFont.xl, "lg" to AppFont.lg, "body" to AppFont.body, "md" to AppFont.md, "base" to AppFont.base,
                    "sm" to AppFont.sm, "xs" to AppFont.xs, "xs2" to AppFont.xs2, "xs3" to AppFont.xs3, "mono" to AppFont.mono())
                    .forEach { (name, style) ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(name, color = p.textMuted, style = AppFont.xs2, modifier = Modifier.width(56.dp))
                            Text("The quick brown fox", color = p.textPrimary, style = style)
                        }
                    }
            }

            Section("Buttons") {
                PillButton("Primary") {}
                PillButton("Busy", busy = true) {}
                PillButton("Disabled", enabled = false) {}
            }

            Section("Inputs") {
                Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2 + 2.dp)) {
                    BasicTextField(sample, { sample = it }, singleLine = true,
                        textStyle = AppFont.sm.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                        modifier = Modifier.fillMaxWidth())
                }
            }

            Section("Tags & badges") {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s2), verticalAlignment = Alignment.CenterVertically) {
                    InboxTag("Action", p.accentDanger); InboxTag("Schedule", p.accentPrimary)
                    InboxTag("Waiting", p.accentAmber); InboxTag("AI", p.accentTeal)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s2), verticalAlignment = Alignment.CenterVertically) {
                    AIBadge("Positive", "face.smiling", p.accentSuccess)
                    AIBadge("Urgent", "exclamationmark.circle", p.accentDanger)
                }
            }

            Section("Gradients") {
                Box(Modifier.fillMaxWidth().height(28.dp).clip(RoundedCornerShape(Radius.full)).background(p.ringGradient))
                Text("ringGradient — avatar rings, the Bridge orb, the loading bar", color = p.textTertiary, style = AppFont.xs2)
            }

            Section("Avatars") {
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s3)) {
                    AvatarRing("WS", seed = 1); AvatarRing("AC", seed = 2); AvatarRing("", icon = "tray", seed = 3)
                    AvatarRing("…", loading = true)
                }
            }

            Section("Card") {
                Column(Modifier.insetCard().padding(Space.s3)) {
                    Text("Inset card", color = p.textPrimary, style = AppFont.md)
                    Text("Raised surface with the faint top-lit border — reader panes, summaries, calendar.",
                        color = p.textTertiary, style = AppFont.xs)
                }
            }
            Spacer(Modifier.height(80.dp))
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    val p = theme
    Column(verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        Text(title.uppercase(), color = p.textTertiary, style = AppFont.ui(13, FontWeight.SemiBold), letterSpacing = androidx.compose.ui.unit.TextUnit(0.5f, androidx.compose.ui.unit.TextUnitType.Sp))
        content()
    }
}
