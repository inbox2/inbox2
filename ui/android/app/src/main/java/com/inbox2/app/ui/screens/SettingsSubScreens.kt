package com.inbox2.app.ui.screens

import com.inbox2.app.ui.components.PillTextButton
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.border
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.ChannelAvatar
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.insetCard
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.launch

/** Connected accounts (iOS Settings → Connected accounts): the account list + add/reconnect/remove. */
@Composable
fun ConnectedAccountsScreen(
    engine: EngineModel,
    cloud: com.inbox2.app.cloud.CloudSession,
    onBack: () -> Unit,
    onAddAccount: () -> Unit,
    onReconnect: (com.inbox2.app.oauth.OAuthProvider?, String?) -> Unit,
) {
    val p = theme
    val scope = rememberCoroutineScope()
    val accounts by engine.accounts.collectAsState()
    var removeTarget by remember { mutableStateOf<com.inbox2.app.engine.AccountRow?>(null) }
    var menuFor by remember { mutableStateOf<String?>(null) }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader(title = "Connected accounts", showBack = true, onBack = onBack) {
            Icon(SfIcon.vector("plus"), "Add account", tint = p.accentViolet,
                modifier = Modifier.size(24.dp).noRippleClickable { onAddAccount() })
        }
        Column(Modifier.insetCard().padding(vertical = Space.s1)) {
            if (accounts.isEmpty()) {
                Text("No accounts connected", color = p.textTertiary, style = AppFont.sm, modifier = Modifier.padding(Space.s4))
            }
            accounts.forEach { a ->
                Column(Modifier.padding(horizontal = Space.s3, vertical = Space.s2)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        ChannelAvatar(label = a.email, seed = a.id, avatarURL = a.avatarURL, provider = a.provider, size = 36.dp)
                        Spacer(Modifier.width(Space.s3))
                        Column(Modifier.weight(1f)) {
                            Text(a.email, color = p.textPrimary, style = AppFont.sm, maxLines = 1)
                            Text(a.provider, color = p.textTertiary, style = AppFont.xs2)
                        }
                        // Status dot: green = healthy, amber = needs re-auth, red = transient
                        // error, muted = not connected yet (iOS statusColor).
                        Box(Modifier.size(8.dp).clip(CircleShape).background(accountStatusColor(a, p)))
                        Spacer(Modifier.width(Space.s2))
                        Box {
                            Icon(SfIcon.vector("ellipsis"), "Account options", tint = p.textSecondary,
                                modifier = Modifier.size(20.dp).noRippleClickable { menuFor = a.id })
                            com.inbox2.app.ui.components.GlassDropdownMenu(menuFor == a.id, onDismissRequest = { menuFor = null }) {
                                DropdownMenuItem(
                                    text = { Text("Reconnect", color = p.textPrimary, style = AppFont.sm) },
                                    onClick = { menuFor = null; onReconnect(providerFor(a.provider), a.email) })
                                DropdownMenuItem(
                                    text = { Text("Remove", color = p.accentDanger, style = AppFont.sm) },
                                    onClick = { menuFor = null; removeTarget = a })
                            }
                        }
                    }
                    if (a.isFailing) AccountErrorBanner(a) { onReconnect(providerFor(a.provider), a.email) }
                    OpenTrackingRow(engine, cloud, a)
                }
            }
        }
        Spacer(Modifier.height(100.dp))
    }

    removeTarget?.let { a ->
        AlertDialog(
            onDismissRequest = { removeTarget = null },
            title = { Text("Remove account?") },

            text = { Text("This removes ${a.email} and its mail from this phone.") },
            confirmButton = { PillButton("Remove", compact = true, tint = theme.accentDanger) { removeTarget = null; scope.launch { engine.removeAccount(a.id) } } },
            dismissButton = { PillTextButton("Cancel") { removeTarget = null } },
        )
    }
}

/** Status-dot colour: green = healthy, amber = needs re-auth (actionable), red = transient
 *  sync error, muted = not connected yet (iOS SettingsView.statusColor). */
private fun accountStatusColor(a: com.inbox2.app.engine.AccountRow, p: com.inbox2.app.theme.ThemePalette): Color = when (a.status) {
    com.inbox2.app.engine.AccountStatusValue.CONNECTED -> p.accentSuccess
    com.inbox2.app.engine.AccountStatusValue.NEEDS_REAUTH -> p.accentAmber
    com.inbox2.app.engine.AccountStatusValue.ERROR -> p.accentDanger
    else -> p.textMuted
}

/** A dead-credentials account (`needs_reauth`) gets a prominent, tappable "Reconnect" CTA;
 *  a transient error shows the reason in a quieter style (iOS AccountErrorBanner). */
@Composable
private fun AccountErrorBanner(a: com.inbox2.app.engine.AccountRow, onReconnect: () -> Unit) {
    val p = theme
    val accent = if (a.needsReauth) p.accentAmber else p.accentDanger
    val headline = when {
        a.needsReauth -> "Your sign-in expired. Reconnect to get new mail."
        a.errorMessage != null -> "Couldn't get mail: ${a.errorMessage}"
        else -> "Couldn't get mail for this account"
    }
    Row(
        Modifier.fillMaxWidth().padding(top = Space.s2)
            .clip(RoundedCornerShape(Radius.lg)).background(accent.copy(alpha = 0.10f))
            .padding(horizontal = Space.s3, vertical = Space.s2),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(SfIcon.vector(if (a.needsReauth) "exclamationmark.triangle" else "exclamationmark.circle"),
            null, tint = accent, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(Space.s2))
        Text(headline, color = p.textSecondary, style = AppFont.xs, modifier = Modifier.weight(1f))
        if (a.needsReauth) {
            Spacer(Modifier.width(Space.s2))
            Text("Reconnect", color = p.textPrimary, style = AppFont.xs2.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold),
                modifier = Modifier
                    .clip(RoundedCornerShape(Radius.full)).background(accent.copy(alpha = 0.22f))
                    .border(1.dp, accent.copy(alpha = 0.45f), RoundedCornerShape(Radius.full))
                    .noRippleClickable { onReconnect() }
                    .padding(horizontal = Space.s3, vertical = 5.dp))
        }
    }
}

/** inbox2 mx (iOS Settings → inbox2 mx): the shared-pool sign-in + privacy proxy / device link. */
@Composable
fun Inbox2MxScreen(
    cloud: com.inbox2.app.cloud.CloudSession,
    engine: EngineModel,
    onBack: () -> Unit,
    onCloudSignIn: () -> Unit,
) {
    val p = theme
    val scope = rememberCoroutineScope()
    val cloudUser by cloud.user.collectAsState()
    val orgs by cloud.orgs.collectAsState()
    val activeOrg by cloud.activeOrg.collectAsState()

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader(title = "inbox2 mx", showBack = true, onBack = onBack)
        val restoring by cloud.restoring.collectAsState()
        var signingOut by remember { mutableStateOf(false) }
        Column(Modifier.insetCard().padding(Space.s4)) {
            val u = cloudUser
            if (u == null && restoring) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.material3.CircularProgressIndicator(color = p.accentViolet, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(Space.s2))
                    Text("Checking session…", color = p.textSecondary, style = AppFont.sm)
                }
            } else if (u == null) {
                Row(Modifier.fillMaxWidth().noRippleClickable { onCloudSignIn() },
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Sign in to inbox2 mx", color = p.textPrimary, style = AppFont.md)
                        Text("Your domain's inbox", color = p.textTertiary, style = AppFont.xs)
                    }
                    Icon(SfIcon.vector("chevron.right"), null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
                }
            } else {
                // Signed in: avatar + name + billing email (iOS CloudAccountPanel).
                Row(verticalAlignment = Alignment.CenterVertically) {
                    com.inbox2.app.ui.components.AvatarRing(u.label.take(2).uppercase(), size = 40.dp,
                        seed = com.inbox2.app.model.MailAddress.seed(u.billingEmail ?: u.username))
                    Spacer(Modifier.width(Space.s3))
                    Column(Modifier.weight(1f)) {
                        Text(u.label, color = p.textPrimary, style = AppFont.md)
                        u.billingEmail?.takeIf { it.isNotEmpty() }?.let { Text(it, color = p.textTertiary, style = AppFont.xs2) }
                            ?: Text("Signed in", color = p.accentSuccess, style = AppFont.xs)
                    }
                }
                // Domains — every org the account belongs to (one or many), the active one
                // checked, tap to switch.
                if (orgs.isNotEmpty()) {
                    Spacer(Modifier.height(Space.s3))
                    Text(if (orgs.size == 1) "DOMAIN" else "DOMAINS", color = p.textTertiary, style = AppFont.xs2)
                    orgs.forEach { org ->
                        Row(
                            Modifier.fillMaxWidth().noRippleClickable { cloud.setActiveOrg(org.id) }
                                .padding(vertical = Space.s2),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(SfIcon.vector("globe"), null, tint = p.accentViolet, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(Space.s3))
                            Column(Modifier.weight(1f)) {
                                Text(org.name, color = p.textPrimary, style = AppFont.sm)
                                org.domain?.takeIf { it.isNotEmpty() }?.let { Text(it, color = p.textTertiary, style = AppFont.xs3) }
                            }
                            if (org.id == activeOrg)
                                Icon(SfIcon.vector("checkmark"), null, tint = p.accentSuccess, modifier = Modifier.size(16.dp))
                        }
                    }
                }
                Spacer(Modifier.height(Space.s3))
                Row(
                    Modifier.fillMaxWidth().noRippleClickable(enabled = !signingOut) {
                        signingOut = true
                        // Tear down the credential vault session too (docs/E2EE.md), so a
                        // different inbox2 account can't upload into this one's vault.
                        engine.clearVaultSession()
                        scope.launch { cloud.signOut(); signingOut = false }
                    },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(SfIcon.vector("rectangle.portrait.and.arrow.right"), null, tint = p.accentDanger, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(Space.s3))
                    Text("Sign out", color = p.accentDanger, style = AppFont.body, modifier = Modifier.weight(1f))
                    if (signingOut) androidx.compose.material3.CircularProgressIndicator(color = p.accentDanger, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                }
            }
        }

        SettingsSectionLabel("Privacy")
        PrivacyCard(cloud)
        Spacer(Modifier.height(100.dp))
    }
}

/** Privacy: load remote images privately through the Rails proxy + the personal API key
 *  the proxy authenticates with (iOS PrivacyStore panel). */
@Composable
private fun PrivacyCard(cloud: com.inbox2.app.cloud.CloudSession) {
    val p = theme
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val privacy = remember { com.inbox2.app.cloud.PrivacyStore(ctx) }
    var proxyOn by remember { mutableStateOf(privacy.proxyEnabled) }
    var saved by remember { mutableStateOf(privacy.apiKey != null) }
    var keyField by remember { mutableStateOf("") }
    var keyStatus by remember { mutableStateOf<String?>(null) }
    var linking by remember { mutableStateOf(false) }

    Column(Modifier.insetCard().padding(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Load remote images privately", color = p.textPrimary, style = AppFont.sm)
                Text("inbox2 fetches them, so senders can't see your device", color = p.textTertiary, style = AppFont.xs2)
            }
            Switch(colors = com.inbox2.app.ui.components.inboxSwitchColors(), checked = proxyOn, onCheckedChange = { proxyOn = it; privacy.proxyEnabled = it })
        }
        if (!saved) {
            PillButton(if (linking) "Waiting for approval…" else "Link to inbox2 account",
                modifier = Modifier.padding(top = Space.s1), busy = linking) {
                linking = true; keyStatus = null
                scope.launch {
                    val res = runCatching { com.inbox2.app.cloud.DeviceLinkService(ctx).link() }
                        .fold(
                            onSuccess = { cloud.adoptLinkedToken(it) },
                            // Backing out of the browser (timeout/cancel) isn't an error (iOS).
                            onFailure = { if (it is kotlinx.coroutines.CancellationException) "" else "Couldn't link this device. ${it.message.orEmpty()}".trim() },
                        )
                    linking = false
                    if (res == null) { saved = true; keyStatus = "Linked" } else if (res.isNotEmpty()) keyStatus = res
                }
            }
            if (cloud.isSignedIn) Text("You're signed in to inbox2 mx, so private image loading already works — linking is for a device that isn't.",
                color = p.textTertiary, style = AppFont.xs2)
            Text("Recommended. You sign in with your browser. You can revoke each device anytime.",
                color = p.textTertiary, style = AppFont.xs2)
            Box(Modifier.fillMaxWidth().height(1.dp).background(p.borderSubtle))
            Text("or", color = p.textTertiary, style = AppFont.xs, modifier = Modifier.align(Alignment.CenterHorizontally))
        }
        Text("inbox2 API key", color = p.textTertiary, style = AppFont.xs, modifier = Modifier.padding(top = Space.s1))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f).clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2)) {
                if (saved) {
                    Text((privacy.apiKey?.take(8) ?: "ink_") + "…", color = p.textSecondary, style = AppFont.sm)
                } else {
                    if (keyField.isEmpty()) Text("ink_…", color = p.textTertiary, style = AppFont.sm)
                    androidx.compose.foundation.text.BasicTextField(
                        value = keyField, onValueChange = { keyField = it; keyStatus = null }, singleLine = true,
                        textStyle = AppFont.sm.copy(color = p.textPrimary),
                        cursorBrush = SolidColor(p.accentViolet), modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            Text(if (saved) "Clear" else "Save", color = if (saved) p.accentViolet else p.textSecondary, style = AppFont.sm,
                modifier = Modifier.padding(start = Space.s3).noRippleClickable {
                    if (saved) {
                        privacy.clearApiKey(); saved = false; keyField = ""; keyStatus = "Cleared"
                    } else {
                        if (privacy.saveApiKey(keyField)) { saved = true; keyField = ""; keyStatus = "Saved" }
                        else keyStatus = "Keys start with ink_"
                    }
                })
        }
        keyStatus?.let { Text(it, color = p.textTertiary, style = AppFont.xs2) }
    }
}

// Per-channel open tracking (docs/Open-Tracking.md): a compact toggle + optional
// custom tracking host, wired to the engine's per-account settings. Mail channels
// only (a WhatsApp/Messenger channel can't carry an email pixel).
@Composable
private fun OpenTrackingRow(engine: EngineModel, cloud: com.inbox2.app.cloud.CloudSession, account: com.inbox2.app.engine.AccountRow) {
    val p = theme
    val scope = rememberCoroutineScope()
    val supported = remember(account.provider) {
        listOf("gmail", "microsoft", "office365", "outlook", "imap").any { account.provider.lowercase().contains(it) }
    }
    if (!supported) return

    // Available only with a cloud identity (mx session or api token) — that's how
    // the config is saved/synced across devices (docs/Open-Tracking.md).
    val signedIn by cloud.user.collectAsState()
    if (signedIn == null) {
        Column(Modifier.padding(top = Space.s2)) {
            Text("Sign in to inbox2 to use open tracking. It works on all your devices.",
                color = p.textTertiary, style = AppFont.xs2)
        }
        return
    }

    // Recommend a subdomain of the channel's OWN sending domain (track.tuli.com for
    // waseem@tuli.com) — same-domain as the From address lowers spam scoring.
    val suggested = remember(account.email) {
        val domain = account.email.substringAfter('@', "").lowercase().trim()
        if (domain.isEmpty()) "track.yourdomain.com" else "track.$domain"
    }

    var loaded by remember(account.id) { mutableStateOf(false) }
    var enabled by remember(account.id) { mutableStateOf(false) }
    var custom by remember(account.id) { mutableStateOf(false) }
    var host by remember(account.id) { mutableStateOf("") }

    LaunchedEffect(account.id) {
        // Cloud is the source of truth; mirror into the local engine (drives injection),
        // then fall back to the local mirror if the channel isn't in the cloud yet.
        val ch = cloud.channelTracking().firstOrNull { it.emailAddress.equals(account.email, ignoreCase = true) }
        if (ch != null) engine.setOpenTracking(account.id, ch.openTrackingEnabled, ch.trackDomain)
        val s = engine.openTrackingSettings(account.id)
        enabled = ch?.openTrackingEnabled ?: s.enabled
        host = (ch?.trackDomain ?: s.trackDomain) ?: ""
        custom = (ch?.trackDomain ?: s.trackDomain) != null
        loaded = true
    }
    if (!loaded) return

    // Persist locally (drives injection) AND to the cloud (syncs to other devices).
    fun save(en: Boolean, td: String?) {
        scope.launch {
            engine.setOpenTracking(account.id, en, td)
            cloud.saveChannelTracking(account.email, en, td)
        }
    }

    Column(Modifier.padding(top = Space.s2), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(SfIcon.vector("eye.fill"), null, tint = p.textSecondary, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(Space.s2))
            Text("Open tracking", color = p.textSecondary, style = AppFont.sm, modifier = Modifier.weight(1f))
            Switch(colors = com.inbox2.app.ui.components.inboxSwitchColors(), checked = enabled, onCheckedChange = {
                enabled = it; save(it, if (custom) host.trim() else null)
            })
        }
        if (enabled) {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s3)) {
                Text("inbox2 domain", color = if (!custom) p.accentViolet else p.textTertiary, style = AppFont.xs2,
                    modifier = Modifier.noRippleClickable { custom = false; host = ""; save(true, null) })
                Text("Your domain", color = if (custom) p.accentViolet else p.textTertiary, style = AppFont.xs2,
                    modifier = Modifier.noRippleClickable { custom = true; if (host.isEmpty()) host = suggested })
            }
            if (custom) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f).clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2)) {
                        if (host.isEmpty()) Text(suggested, color = p.textTertiary, style = AppFont.sm)
                        androidx.compose.foundation.text.BasicTextField(
                            value = host, onValueChange = { host = it }, singleLine = true,
                            textStyle = AppFont.sm.copy(color = p.textPrimary),
                            cursorBrush = SolidColor(p.accentViolet), modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    Text("Save", color = p.accentViolet, style = AppFont.sm,
                        modifier = Modifier.padding(start = Space.s3).noRippleClickable { save(true, host.trim()) })
                }
                Text("Use a subdomain of the domain you send from. Spam filters trust it more. Point a CNAME from it to visit.inbox2.com. On Cloudflare, keep the cloud grey.",
                    color = p.textTertiary, style = AppFont.xs3)
            }
        }
    }
}
