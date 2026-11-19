package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import com.inbox2.app.SecureStore
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.inbox2.app.engine.AccountRow
import com.inbox2.app.engine.EngineModel
import com.inbox2.app.oauth.OAuthProvider
import com.inbox2.app.oauth.OAuthService
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.SfIcon
import com.inbox2.app.ui.components.insetCard
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.launch

/** Add account (iOS AddAccountView): Google / Microsoft (loopback OAuth) / IMAP form. */
@Composable
fun AddAccountScreen(
    engine: EngineModel, onClose: () -> Unit, presetProvider: OAuthProvider? = null,
    presetLoginHint: String? = null,
    title: String = "Add account", showBack: Boolean = true, onCloudSignIn: (() -> Unit)? = null,
    /** Reconnect an IMAP account: straight into the form (iOS reauthIMAP). */
    presetImap: Boolean = false,
) {
    val p = theme
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var mode by remember { mutableStateOf<String?>(if (presetImap) "imap" else null) }   // null = picker, "imap" = form
    // Reconnect: one obvious thing to retry, so the picker shows just that provider.
    val isReauth = presetProvider != null || presetImap
    var lastProvider by remember { mutableStateOf(presetProvider) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // Cloud credential backup (docs/E2EE.md). On by default; only effective when a
    // cloud bearer exists (signed into inbox2) — the vault unlocks with that password.
    var cloudBackup by remember { mutableStateOf(true) }
    val canBackup = remember {
        SecureStore.get(ctx, SecureStore.MX_TOKEN) != null || SecureStore.get(ctx, SecureStore.INK_API_KEY) != null
    }
    val effectiveBackup = canBackup && cloudBackup

    fun startOAuth(provider: OAuthProvider, loginHint: String? = null) {
        busy = true; error = null
        scope.launch {
            runCatching {
                val tokens = OAuthService(ctx).connect(provider, loginHint)
                val (ok, value) = engine.addAccount(
                    providerType = provider.providerType, email = tokens.email, displayName = tokens.email,
                    authMethod = "xoauth2", accessToken = tokens.accessToken, refreshToken = tokens.refreshToken,
                    cloudBackup = effectiveBackup,
                )
                if (!ok) error = value else onClose()
            }.onFailure { error = friendlyMessage(it) }
            busy = false
        }
    }
    fun start(provider: OAuthProvider, hint: String? = null) { lastProvider = provider; startOAuth(provider, hint) }

    LaunchedEffect(presetProvider) { presetProvider?.let { startOAuth(it, presetLoginHint) } }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader(title = if (isReauth) "Reconnect${presetLoginHint?.let { " $it" } ?: ""}" else title, showBack = showBack, onBack = onClose)
        if (busy) {
            Text("Connecting…", color = p.textSecondary, style = AppFont.md, modifier = Modifier.padding(Space.s4))
        }
        error?.let {
            Text(it, color = p.accentDanger, style = AppFont.xs, modifier = Modifier.padding(horizontal = Space.s4))
            // In reconnect there's one obvious thing to retry; in "add" the chooser is right there.
            if (isReauth && !busy && lastProvider != null) Text("Try again", color = p.accentViolet, style = AppFont.ui(13, androidx.compose.ui.text.font.FontWeight.SemiBold),
                modifier = Modifier.padding(horizontal = Space.s4, vertical = Space.s1).noRippleClickable { start(lastProvider!!, presetLoginHint) })
        }

        when (mode) {
            null -> if (isReauth) {
                // Reconnect: a single card for the known provider.
                when (presetProvider) {
                    OAuthProvider.GOOGLE -> ProviderButton("Google", "ch-gmail", enabled = !busy) { start(OAuthProvider.GOOGLE, presetLoginHint) }
                    OAuthProvider.MICROSOFT -> ProviderButton("Microsoft", "ch-microsoft", enabled = !busy) { start(OAuthProvider.MICROSOFT, presetLoginHint) }
                    else -> ProviderButton("IMAP / SMTP", "envelope", enabled = !busy) { mode = "imap" }
                }
            } else {
                ProviderButton("Google", "ch-gmail", enabled = !busy) { start(OAuthProvider.GOOGLE) }
                ProviderButton("Microsoft", "ch-microsoft", enabled = !busy) { start(OAuthProvider.MICROSOFT) }
                ProviderButton("IMAP / SMTP", "envelope", enabled = !busy) { mode = "imap" }
                // Meta BYOK channels (see docs/Cloud-Push.md Meta).
                MetaLogoButton("WhatsApp", com.inbox2.app.R.drawable.ch_whatsapp) { mode = "meta:whatsapp" }
                MetaLogoButton("Messenger", com.inbox2.app.R.drawable.ch_messenger) { mode = "meta:messenger" }
                MetaLogoButton("Instagram", com.inbox2.app.R.drawable.ch_instagram) { mode = "meta:instagram" }
                onCloudSignIn?.let { ProviderButton("inbox2 mx · your domain's inbox", "person.2") { it() } }

                // Cloud credential backup toggle (docs/E2EE.md).
                Row(
                    Modifier.insetCard().padding(Space.s4),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Save logins to your inbox2 account", color = p.textPrimary, style = AppFont.body)
                        Text(
                            if (canBackup) "We encrypt them. On a new phone, you skip signing in again."
                            else "Sign in to inbox2 to turn this on.",
                            color = p.textSecondary, style = AppFont.xs,
                        )
                    }
                    Spacer(Modifier.width(Space.s3))
                    Switch(colors = com.inbox2.app.ui.components.inboxSwitchColors(), checked = effectiveBackup, enabled = canBackup, onCheckedChange = { cloudBackup = it })
                }
            }
            "imap" -> ImapForm(engine, onClose, cloudBackup = effectiveBackup, setBusy = { busy = it }, setError = { error = it })
            else -> if (mode!!.startsWith("meta:")) {
                MetaForm(engine, channel = mode!!.removePrefix("meta:"), onClose = onClose,
                    cloudBackup = effectiveBackup, setBusy = { busy = it }, setError = { error = it })
            }
        }
        Spacer(Modifier.height(40.dp))
    }
}

@Composable
private fun ProviderButton(label: String, icon: String, enabled: Boolean = true, onClick: () -> Unit) {
    val p = theme
    Row(
        Modifier.insetCard().padding(Space.s4).alpha(if (enabled) 1f else 0.55f)
            .noRippleClickable(enabled = enabled) { onClick() },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(SfIcon.vector(icon), label, tint = p.accentViolet, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(Space.s3))
        Text(label, color = p.textPrimary, style = AppFont.body)
    }
}

/** Provider row with a full-colour brand logo (vs the tinted SF symbol used by mail). */
@Composable
private fun MetaLogoButton(label: String, drawable: Int, onClick: () -> Unit) {
    val p = theme
    Row(
        Modifier.insetCard().padding(Space.s4)
            .noRippleClickable { onClick() },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        androidx.compose.foundation.Image(
            painter = androidx.compose.ui.res.painterResource(drawable),
            contentDescription = label, modifier = Modifier.size(24.dp),
        )
        Spacer(Modifier.width(Space.s3))
        Text(label, color = p.textPrimary, style = AppFont.body)
    }
}

/** One connected Meta app, for credential reuse. Several channels can share an
 *  app's secret + System User token; `repKey` is the account whose encrypted
 *  bundle gets reused. Accounts without a known app id form their own group. */
data class MetaAppGroup(val key: String, val appId: String?, val repKey: String, val channels: List<AccountRow>) {
    val label: String
        get() {
            val chans = channels.joinToString(", ") { metaChannelDisplay(it.provider) }
            val base = appId?.let { "App $it" } ?: channels.firstOrNull()?.email ?: "Existing Meta app"
            return if (chans.isEmpty()) base else "$base · $chans"
        }
}

private fun metaChannelDisplay(provider: String): String = provider.lowercase().let {
    when {
        it.contains("whatsapp") -> "WhatsApp"
        it.contains("messenger") -> "Messenger"
        it.contains("instagram") -> "Instagram"
        else -> provider
    }
}

/** Group connected Meta accounts by app for the reuse picker, preserving order. */
fun metaAppGroups(accounts: List<AccountRow>): List<MetaAppGroup> {
    val order = mutableListOf<String>()
    val groups = linkedMapOf<String, MutableList<AccountRow>>()
    for (a in accounts) {
        val p = a.provider.lowercase()
        if (!(p.contains("whatsapp") || p.contains("messenger") || p.contains("instagram"))) continue
        val key = a.metaAppId?.let { "app:$it" } ?: "acct:${a.id}"
        if (groups[key] == null) { order.add(key); groups[key] = mutableListOf() }
        groups[key]!!.add(a)
    }
    return order.mapNotNull { key ->
        val rows = groups[key] ?: return@mapNotNull null
        MetaAppGroup(key, rows.first().metaAppId, rows.first().id, rows)
    }
}

/** BYOK Meta connect form. Shared app-secret bundle + per-channel asset ids.
 *  When other Meta channels exist, their app credentials can be reused. */
@Composable
private fun MetaForm(engine: EngineModel, channel: String, onClose: () -> Unit, cloudBackup: Boolean = false, setBusy: (Boolean) -> Unit, setError: (String?) -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    val accounts by engine.accounts.collectAsState()
    val metaApps = remember(accounts) { metaAppGroups(accounts) }
    var displayName by remember { mutableStateOf("") }
    var appId by remember { mutableStateOf("") }
    var appSecret by remember { mutableStateOf("") }
    var token by remember { mutableStateOf("") }
    var pageId by remember { mutableStateOf("") }
    var igId by remember { mutableStateOf("") }
    var phoneId by remember { mutableStateOf("") }
    var wabaId by remember { mutableStateOf("") }
    // Default to reuse when an app already exists (the toggle's purpose).
    var reuseExisting by remember(metaApps.isNotEmpty()) { mutableStateOf(metaApps.isNotEmpty()) }
    var reuseFrom by remember { mutableStateOf("") }
    LaunchedEffect(metaApps) {
        if (reuseFrom.isBlank() && metaApps.isNotEmpty()) reuseFrom = metaApps.first().repKey
    }
    val reusing = reuseExisting && metaApps.isNotEmpty()

    // App ID is optional (only enables automatic webhook setup); the secondary
    // asset (phone / IG account) is auto-derived on connect, so one id per channel.
    val canConnect = (if (reusing) reuseFrom.isNotBlank() else appSecret.isNotBlank() && token.isNotBlank()) && when (channel) {
        "whatsapp" -> wabaId.isNotBlank()
        "messenger" -> pageId.isNotBlank()
        "instagram" -> pageId.isNotBlank()
        else -> false
    }

    Column(Modifier.padding(horizontal = Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        // Connecting auto-subscribes the app's webhook + starts receiving.
        Text("Use your own Meta app. Your keys stay encrypted on this phone. We set up its webhook when you connect.",
            color = p.textSecondary, style = AppFont.xs)

        if (metaApps.isNotEmpty()) {
            // Use-existing / add-new pill toggle.
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.full)).background(p.bgInput).padding(3.dp),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                listOf(true to "Use existing", false to "Add new").forEach { (value, label) ->
                    val active = reuseExisting == value
                    Box(
                        Modifier.weight(1f).clip(RoundedCornerShape(Radius.full))
                            .background(if (active) p.bgElevated else androidx.compose.ui.graphics.Color.Transparent)
                            .noRippleClickable { reuseExisting = value }
                            .padding(vertical = Space.s2),
                        contentAlignment = Alignment.Center,
                    ) { Text(label, color = if (active) p.textPrimary else p.textTertiary, style = AppFont.sm) }
                }
            }
        }

        if (reusing) {
            MetaAppDropdown(metaApps, reuseFrom) { reuseFrom = it }
            Text("Uses this app's saved secret and System User token.",
                color = p.textTertiary, style = AppFont.xs2)
        } else {
            // App id + display name are auto-derived from the token — no fields.
            Field("App secret", appSecret, isPassword = true) { appSecret = it }
            Field("System User token", token, isPassword = true) { token = it }
        }
        // Secondary asset (phone / IG account) is auto-detected on connect — no field.
        when (channel) {
            "whatsapp" -> Field("WhatsApp Business Account ID", wabaId) { wabaId = it }
            "messenger" -> Field("Facebook Page ID", pageId) { pageId = it }
            "instagram" -> Field("Facebook Page ID", pageId) { pageId = it }
        }
        PillButton("Connect", enabled = canConnect) {
            setBusy(true); setError(null)
            scope.launch {
                // Reuse path: core copies the secret + token from the chosen
                // account, so send them empty and pass the source key.
                val (ok, value) = engine.addMetaAccount(
                    channel = channel, displayName = displayName.ifBlank { null },
                    appId = if (reusing) "" else appId,
                    appSecret = if (reusing) "" else appSecret,
                    systemUserToken = if (reusing) "" else token,
                    facebookPageId = pageId.ifBlank { null }, instagramAccountId = igId.ifBlank { null },
                    whatsappPhoneNumberId = phoneId.ifBlank { null }, whatsappBusinessAccountId = wabaId.ifBlank { null },
                    reuseCredentialsFrom = if (reusing) reuseFrom else null,
                    cloudBackup = cloudBackup,
                )
                setBusy(false)
                if (ok) onClose() else setError(value)
            }
        }
    }
}

/** Dropdown picker of existing Meta apps for credential reuse. */
@Composable
private fun MetaAppDropdown(apps: List<MetaAppGroup>, selectedKey: String, onSelect: (String) -> Unit) {
    val p = theme
    var open by remember { mutableStateOf(false) }
    val selected = apps.firstOrNull { it.repKey == selectedKey } ?: apps.firstOrNull()
    Column {
        Text("Meta app", color = p.textTertiary, style = AppFont.xs2)
        Box {
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(p.bgInput)
                    .noRippleClickable { open = true }
                    .padding(Space.s2 + 2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(selected?.label ?: "Select", color = p.textPrimary, style = AppFont.sm, modifier = Modifier.weight(1f))
                Icon(SfIcon.vector("chevron.down"), contentDescription = null, tint = p.textTertiary, modifier = Modifier.size(16.dp))
            }
            androidx.compose.material3.DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                apps.forEach { app ->
                    androidx.compose.material3.DropdownMenuItem(
                        text = { Text(app.label, color = p.textPrimary, style = AppFont.sm) },
                        onClick = { onSelect(app.repKey); open = false },
                    )
                }
            }
        }
    }
}

@Composable
private fun ImapForm(engine: EngineModel, onClose: () -> Unit, cloudBackup: Boolean = false, setBusy: (Boolean) -> Unit, setError: (String?) -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("993") }
    var smtpHost by remember { mutableStateOf("") }
    // Implicit TLS on both: 993 / 465 (iOS IMAPConnectView) — 587 with implicit TLS won't connect.
    var smtpPort by remember { mutableStateOf("465") }
    val email_ = androidx.compose.foundation.text.KeyboardOptions(capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = androidx.compose.ui.text.input.KeyboardType.Email)
    val host_ = androidx.compose.foundation.text.KeyboardOptions(capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = androidx.compose.ui.text.input.KeyboardType.Uri)
    val num_ = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number)

    Column(Modifier.padding(horizontal = Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s2)) {
        Field("Email", email, keyboardOptions = email_) { email = it }
        Field("Password", password, isPassword = true, keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Password)) { password = it }
        Field("IMAP host", host, keyboardOptions = host_) { host = it }
        Field("IMAP port", port, keyboardOptions = num_) { port = it }
        Field("SMTP host", smtpHost, keyboardOptions = host_, hint = "Leave blank to use the IMAP host") { smtpHost = it }
        Field("SMTP port", smtpPort, keyboardOptions = num_) { smtpPort = it }
        PillButton("Connect", enabled = email.isNotBlank() && host.isNotBlank() && password.isNotEmpty()) {
            setBusy(true); setError(null)
            scope.launch {
                val (ok, value) = engine.addAccount(
                    providerType = "imap", email = email, displayName = email, authMethod = "plain",
                    password = password, host = host, port = port.toUShortOrNull(), useTls = true,
                    smtpHost = smtpHost.ifBlank { null }, smtpPort = smtpPort.toUShortOrNull(), smtpUseTls = true,
                    cloudBackup = cloudBackup,
                )
                setBusy(false)
                if (ok) onClose() else setError(value)
            }
        }
    }
}

@Composable
private fun Field(label: String, value: String, isPassword: Boolean = false,
                  keyboardOptions: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
                  hint: String? = null, onChange: (String) -> Unit) {
    val p = theme
    Column {
        Text(label, color = p.textTertiary, style = AppFont.xs2)
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2 + 2.dp)) {
            if (value.isEmpty() && hint != null) Text(hint, color = p.textMuted, style = AppFont.sm)
            BasicTextField(
                value = value, onValueChange = onChange, singleLine = true, keyboardOptions = keyboardOptions,
                textStyle = AppFont.sm.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                visualTransformation = if (isPassword) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** A short, human message for an OAuth/network failure — never the raw exception dump
 *  (iOS AddAccountView.friendlyMessage). */
private fun friendlyMessage(e: Throwable): String = when (e) {
    is java.net.UnknownHostException -> "No internet connection. Reconnect and try again."
    is java.net.ConnectException, is java.net.SocketTimeoutException, is java.net.NoRouteToHostException ->
        "Couldn't reach the sign-in server. Check your connection and try again."
    is kotlinx.coroutines.CancellationException -> "Sign-in was cancelled."
    else -> e.message?.takeIf { it.isNotBlank() } ?: "Couldn't connect."
}
