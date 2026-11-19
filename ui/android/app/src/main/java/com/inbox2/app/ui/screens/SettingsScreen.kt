package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.darkKeycap
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.noRippleClickable

/**
 * Settings (iOS SettingsView): a compact menu of category rows that push to detail screens
 * — General (Preferences / Connected accounts / inbox2 mx / Theme), Intelligence (Contacts /
 * On-device AI / Triage & sync / Auto rules), Security & compliance (App logs / Developer).
 */
@Composable
fun SettingsScreen(
    engine: EngineModel,
    onConnectedAccounts: () -> Unit = {},
    onInbox2Mx: () -> Unit = {},
    onModelPanel: () -> Unit = {},
    onTriagePanel: () -> Unit = {},
    onRules: () -> Unit = {},
    onTheme: () -> Unit = {},
    onPreferences: () -> Unit = {},
    onContacts: () -> Unit = {},
    onAppLogs: () -> Unit = {},
    onDev: () -> Unit = {},
) {
    val p = theme
    val status by engine.status.collectAsState()

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader(title = "Settings")

        SettingsSectionLabel("General")
        SettingsGroup {
            SettingsMenuRow("Preferences", "gearshape", onPreferences)
            SettingsMenuRow("Connected accounts", "person.crop.circle.badge.plus", onConnectedAccounts)
            SettingsMenuRow("inbox2 mx", "person.crop.circle", onInbox2Mx)
            SettingsMenuRow("Theme", "photo", onTheme)
        }

        SettingsSectionLabel("Intelligence")
        SettingsGroup {
            SettingsMenuRow("Contacts", "person.2", onContacts)
            SettingsMenuRow("On-device AI", "waveform", onModelPanel)
            SettingsMenuRow("Triage & sync", "sparkles", onTriagePanel)
            SettingsMenuRow("Auto rules", "exclamationmark.circle", onRules)
        }

        SettingsSectionLabel("Security & compliance")
        SettingsGroup { SettingsMenuRow("App logs", "doc", onAppLogs) }

        // Developer tools: the same outlined DEV MODE button iOS shows (long-pressing About
        // still works for muscle memory).
        Row(
            Modifier.padding(horizontal = Space.s5).padding(top = Space.s3).fillMaxWidth()
                // Groovebox: a dark keycap instead of the violet outline.
                .then(p.groove?.let { Modifier.darkKeycap(it, Radius.lg) } ?: Modifier)
                .clip(RoundedCornerShape(Radius.lg))
                .then(if (p.groove == null) Modifier.border(1.dp, p.accentViolet.copy(alpha = 0.5f), RoundedCornerShape(Radius.lg)) else Modifier)
                .noRippleClickable { onDev() }.padding(vertical = Space.s3),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(SfIcon.vector("ladybug"), null, tint = p.accentViolet, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(Space.s2))
            Text("DEV MODE", color = p.accentViolet, style = AppFont.ui(14, FontWeight.Bold),
                letterSpacing = androidx.compose.ui.unit.TextUnit(0.6f, androidx.compose.ui.unit.TextUnitType.Sp))
        }

        SettingsSectionLabel("About")
        // Long-press About also opens the developer tools.
        Column(Modifier.padding(horizontal = Space.s3).clip(RoundedCornerShape(if (p.groove != null) Radius.xl else Radius.lg))
            .background(if (p.groove != null) p.bgPanel else p.bgElevated)
            .pointerInput(Unit) { detectTapGestures(onLongPress = { onDev() }) }
            .padding(Space.s4)) {
            Text("inbox2 for Android", color = p.textPrimary, style = AppFont.md)
            Text("engine: $status", color = p.textTertiary, style = AppFont.xs)
            Text("Shared Rust core via UniFFI · Compose UI", color = p.textTertiary, style = AppFont.xs2,
                modifier = Modifier.padding(top = Space.s1))
        }
        Spacer(Modifier.height(100.dp))
    }
}

@Composable
internal fun SettingsSectionLabel(text: String) {
    Text(
        text.uppercase(), color = theme.textTertiary, style = AppFont.label(12),
        modifier = Modifier.padding(horizontal = Space.s5, vertical = Space.s2).padding(top = Space.s3),
    )
}

/** A run of settings rows. Groovebox groups them on one solid panel (radius 20);
 *  other themes keep the bare rows. */
@Composable
internal fun SettingsGroup(content: @Composable () -> Unit) {
    val p = theme
    Column(if (p.groove != null) Modifier.padding(horizontal = Space.s3).clip(RoundedCornerShape(Radius.xl)).background(p.bgPanel) else Modifier) {
        content()
    }
}

@Composable
private fun SettingsMenuRow(title: String, icon: String, onClick: () -> Unit) {
    val p = theme
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 4.dp).clip(RoundedCornerShape(Radius.lg))
            .noRippleClickable { onClick() }
            .padding(horizontal = Space.s4, vertical = Space.s3),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(SfIcon.vector(icon), title, tint = p.textSecondary, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(Space.s3))
        Text(title, color = p.textPrimary, style = AppFont.body, modifier = Modifier.weight(1f))
        Icon(SfIcon.vector("chevron.right"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
    }
}

/** Map a stored provider string to an OAuth provider (null = IMAP/unknown → picker). */
internal fun providerFor(provider: String): com.inbox2.app.oauth.OAuthProvider? = when {
    provider.contains("gmail", true) || provider.contains("google", true) -> com.inbox2.app.oauth.OAuthProvider.GOOGLE
    provider.contains("micro", true) || provider.contains("office", true) || provider.contains("outlook", true) -> com.inbox2.app.oauth.OAuthProvider.MICROSOFT
    else -> null
}
