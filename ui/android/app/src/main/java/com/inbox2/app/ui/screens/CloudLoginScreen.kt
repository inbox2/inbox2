package com.inbox2.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.cloud.DeviceLinkService
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Radius
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.ScreenHeader
import com.inbox2.app.ui.components.noRippleClickable
import kotlinx.coroutines.launch

/** inbox2 mx sign-in (iOS CloudLoginView). Bearer-token login (+2FA) against the API. */
@Composable
fun CloudLoginScreen(cloud: CloudSession, onClose: () -> Unit) {
    val p = theme
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var totp by remember { mutableStateOf("") }
    var need2fa by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var linking by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(p.bgBase).verticalScroll(rememberScrollState())) {
        ScreenHeader("inbox2 mx", showBack = true, onBack = onClose)
        Column(Modifier.padding(Space.s4), verticalArrangement = Arrangement.spacedBy(Space.s3)) {
            Text("Sign in to your domain's inbox.", color = p.textTertiary, style = AppFont.sm)
            LoginField("Username", username, enabled = !need2fa,
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(capitalization = androidx.compose.ui.text.input.KeyboardCapitalization.None,
                    autoCorrectEnabled = false, keyboardType = androidx.compose.ui.text.input.KeyboardType.Email, imeAction = androidx.compose.ui.text.input.ImeAction.Next)) { username = it }
            LoginField("Password", password, isPassword = true, enabled = !need2fa,
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Password, imeAction = androidx.compose.ui.text.input.ImeAction.Done)) { password = it }
            if (need2fa) LoginField("2FA code", totp,
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.NumberPassword, imeAction = androidx.compose.ui.text.input.ImeAction.Done)) { totp = it }
            error?.let { Text(it, color = p.accentDanger, style = AppFont.xs) }
            val canSubmit = username.isNotBlank() && password.isNotEmpty() && !busy && (!need2fa || totp.isNotBlank())
            PillButton(if (busy) "Signing in…" else "Sign in", busy = busy, enabled = canSubmit) {
                busy = true; error = null
                scope.launch {
                    val res = cloud.login(username, password, totp.ifBlank { null })
                    busy = false
                    when (res) {
                        null -> onClose()
                        "2fa" -> need2fa = true
                        else -> error = res
                    }
                }
            }

            Text("or", color = p.textTertiary, style = AppFont.xs, modifier = Modifier.align(Alignment.CenterHorizontally))

            // Device-link: approve this device from an already-signed-in web session
            // (loopback + PKCE handshake), then adopt the minted token as the bearer.
            Box(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.full)).background(p.bgInput)
                    .noRippleClickable(enabled = !busy) {
                        busy = true; error = null; linking = true
                        scope.launch {
                            val res = runCatching { DeviceLinkService(context).link() }
                                .fold(
                                    onSuccess = { cloud.adoptLinkedToken(it) },
                                    // Backing out of the browser isn't an error (iOS).
                                    onFailure = { if (it is kotlinx.coroutines.CancellationException) "" else "Couldn't link this device. ${it.message.orEmpty()}".trim() },
                                )
                            busy = false; linking = false
                            if (res == null) onClose() else if (res.isNotEmpty()) error = res
                        }
                    }.padding(vertical = Space.s3),
                contentAlignment = Alignment.Center,
            ) { Text(if (linking) "Waiting for approval…" else "Link to inbox2 account", color = p.textPrimary, style = AppFont.md) }

            // "Advanced" reads as a link; tapping it reveals a labelled Server URL field
            // (iOS CloudLoginView). Saved as typed; blank restores the default.
            var showAdvanced by remember { mutableStateOf(false) }
            var apiBase by remember { mutableStateOf(com.inbox2.app.AppConfig.apiBase) }
            Row(
                Modifier.padding(start = Space.s3, top = Space.s2).noRippleClickable { showAdvanced = !showAdvanced },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Advanced", color = p.accentViolet, style = AppFont.sm)
                Spacer(Modifier.width(Space.s1))
                androidx.compose.material3.Icon(
                    com.inbox2.app.ui.components.SfIcon.vector(if (showAdvanced) "chevron.up" else "chevron.down"), null,
                    tint = p.accentViolet, modifier = Modifier.size(12.dp))
            }
            if (showAdvanced) {
                LoginField("Server URL", apiBase) { apiBase = it; com.inbox2.app.AppConfig.setApiBase(context, it) }
                Text("Defaults to ${com.inbox2.app.AppConfig.DEFAULT_API_BASE}. The sync engine picks a change up on the next launch.",
                    color = p.textTertiary, style = AppFont.xs2)
            }
        }
    }
}

@Composable
private fun LoginField(label: String, value: String, isPassword: Boolean = false, enabled: Boolean = true,
                       keyboardOptions: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
                       onChange: (String) -> Unit) {
    val p = theme
    Column(Modifier.alpha(if (enabled) 1f else 0.55f)) {
        Text(label, color = p.textTertiary, style = AppFont.xs2)
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(Radius.md)).background(p.bgInput).padding(Space.s2 + 2.dp)) {
            BasicTextField(
                value = value, onValueChange = onChange, singleLine = true, enabled = enabled, keyboardOptions = keyboardOptions,
                textStyle = AppFont.sm.copy(color = p.textPrimary), cursorBrush = SolidColor(p.accentViolet),
                visualTransformation = if (isPassword) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
