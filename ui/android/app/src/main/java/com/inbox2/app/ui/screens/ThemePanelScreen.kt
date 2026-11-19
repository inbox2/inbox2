package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.Image
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.inbox2.app.theme.AppIconOption
import com.inbox2.app.theme.Appearance
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.ThemeManager
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.noRippleClickable

/** Theme picker (iOS ThemePanel): System / Dark / Light, then the app-icon picker. */
@Composable
fun ThemePanelScreen(themeManager: ThemeManager, onBack: () -> Unit) {
    val p = theme
    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader("Theme", showBack = true, onBack = onBack)
        Appearance.entries.forEach { a ->
            val active = themeManager.appearance == a
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 4.dp).clip(RoundedCornerShape(Radius.lg))
                    .noRippleClickable { themeManager.set(a) }
                    .padding(horizontal = Space.s4, vertical = Space.s3),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(a.title, color = p.textPrimary, style = AppFont.body, modifier = Modifier.weight(1f))
                if (active) Icon(SfIcon.vector("checkmark"), null, tint = p.accentViolet, modifier = Modifier.size(20.dp))
            }
        }

        SettingsSectionLabel("App icon")
        val ctx = LocalContext.current
        // Re-read on a theme change: picking Groovebox switches the icon too.
        var icon by remember(themeManager.appearance) { mutableStateOf(AppIconOption.current(ctx)) }
        AppIconOption.entries.forEach { option ->
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 4.dp).clip(RoundedCornerShape(Radius.lg))
                    .noRippleClickable {
                        AppIconOption.select(ctx, option)
                        icon = option
                    }
                    .padding(horizontal = Space.s4, vertical = Space.s3),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Image(
                    painterResource(option.preview), null, contentScale = ContentScale.Fit,
                    modifier = Modifier.size(44.dp).clip(RoundedCornerShape(Radius.lg)),
                )
                Spacer(Modifier.width(Space.s3))
                Column(Modifier.weight(1f)) {
                    Text(option.label, color = p.textPrimary, style = AppFont.body)
                    Text(option.blurb, color = p.textTertiary, style = AppFont.xs2)
                }
                if (icon == option) {
                    Icon(SfIcon.vector("checkmark"), null, tint = p.accentViolet, modifier = Modifier.size(20.dp))
                }
            }
        }
        Text(
            "Changes your home screen icon. Some launchers show it after a refresh.",
            color = p.textTertiary, style = AppFont.xs2,
            modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2),
        )
    }
}
