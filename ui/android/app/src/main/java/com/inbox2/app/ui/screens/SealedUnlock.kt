package com.inbox2.app.ui.screens

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import com.inbox2.app.cloud.CloudSession
import com.inbox2.app.cloud.SealedKeys
import com.inbox2.app.ui.components.PillButton
import com.inbox2.app.ui.components.PillTextButton
import com.inbox2.app.theme.AppFont
import com.inbox2.app.theme.Space
import com.inbox2.app.theme.theme
import kotlinx.coroutines.launch

private suspend fun stillLocked(cloud: CloudSession, orgId: String, conversationId: String) =
    runCatching { cloud.thread(orgId, conversationId).sealedLocked }.getOrDefault(true)

/** The bar over a thread holding sealed mail this phone can't open yet. Tries the
 *  fingerprint once on its own; the button tries it again, then asks for the password. */
@Composable
internal fun SealedBanner(cloud: CloudSession, orgId: String, conversationId: String) {
    val p = theme
    val activity = LocalContext.current as Activity
    val scope = rememberCoroutineScope()
    var asking by remember { mutableStateOf(false) }

    suspend fun useSavedKey(orAsk: Boolean) {
        val key = SealedKeys.load(activity)
        // The key can be fine and this mail still shut: then the password dialog says so.
        if (key != null && cloud.unlockSealed(key) && !stillLocked(cloud, orgId, conversationId)) { cloud.sealedChanged(); return }
        if (orAsk) asking = true
    }
    LaunchedEffect(conversationId) { if (SealedKeys.hasKey(activity)) useSavedKey(orAsk = false) }

    Row(Modifier.padding(horizontal = Space.s4), verticalAlignment = Alignment.CenterVertically) {
        Text("This mail is sealed.", style = AppFont.sm, color = p.textSecondary)
        Spacer(Modifier.weight(1f))
        PillTextButton("Unlock") { scope.launch { useSavedKey(orAsk = true) } }
    }
    if (asking) SealedUnlockDialog(cloud, activity, orgId, conversationId) { asking = false }
}

@Composable
private fun SealedUnlockDialog(cloud: CloudSession, activity: Activity, orgId: String, conversationId: String, onDone: () -> Unit) {
    val p = theme
    val scope = rememberCoroutineScope()
    val canSave = remember { SealedKeys.available(activity) }
    var password by remember { mutableStateOf("") }
    var saveKey by remember { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var unlocked by remember { mutableStateOf(false) }

    // The reload removes the bar and this dialog with it: last, and only once it's over.
    fun finish() {
        onDone()
        if (unlocked) cloud.sealedChanged()
    }

    fun unlock() = scope.launch {
        busy = true; error = null
        val result = cloud.unlockIdentity(password)
        when {
            result == null -> error = "No connection."
            result.key == null -> error = "That password doesn't open your key."
            !cloud.unlockSealed(result.key) -> error = "Your key didn't open this mail."
            else -> {
                if (stillLocked(cloud, orgId, conversationId)) {
                    error = "Your key didn't open this mail."
                } else {
                    unlocked = true
                    if (saveKey && canSave && !SealedKeys.save(activity, result.key)) {
                        error = "Mail unlocked. Fingerprint not saved."
                    } else {
                        finish()
                    }
                }
            }
        }
        busy = false
    }

    AlertDialog(
        onDismissRequest = ::finish,
        title = { Text("Unlock your key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Space.s2)) {
                OutlinedTextField(password, { password = it }, label = { Text("inbox2 password") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password))
                if (canSave) Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Use fingerprint next time", style = AppFont.sm, color = p.textSecondary, modifier = Modifier.weight(1f))
                    Switch(saveKey, { saveKey = it })
                }
                error?.let { Text(it, color = p.accentDanger, style = AppFont.xs) }
            }
        },
        confirmButton = { PillButton("Unlock", compact = true, busy = busy, enabled = password.isNotEmpty()) { unlock() } },
        dismissButton = { PillTextButton("Cancel", enabled = !busy) { finish() } },
    )
}
