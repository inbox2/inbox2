package com.inbox2.app.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.inbox2.app.engine.MarkReadMode
import com.inbox2.app.engine.MarkReadPrefs
import com.inbox2.app.notify.NotificationHelper
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Mark-as-read honoring the user's mode (iOS MarkReadManager): immediate / after a
 *  dwell delay / when leaving the thread / never. Idempotent (only fires while still
 *  unread, once per conversation). Clears the thread's notification alongside (the
 *  launcher badge is notification-driven).
 *
 *  Lifecycle: everything is keyed on [convoId], so switching conversations cancels a
 *  pending dwell timer and resets the once-guard; leaving the surface mid-dwell
 *  cancels the timer outright. SELECTION_CHANGE fires from onDispose — both when the
 *  conversation changes and when the surface leaves composition.
 *
 *  [act] performs the mark-read write (the caller routes it to the engine/cloud). */
@Composable
fun rememberMarkRead(convoId: String, unread: Boolean, act: suspend () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { MarkReadPrefs(ctx) }
    var marked by remember(convoId) { mutableStateOf(false) }
    suspend fun markNow() {
        if (marked || !unread) return
        marked = true
        NotificationHelper.removeDelivered(ctx, listOf(convoId))
        act()
    }
    LaunchedEffect(convoId) {
        when (prefs.mode) {
            MarkReadMode.IMMEDIATE -> markNow()
            MarkReadMode.DELAY -> { delay(prefs.delaySeconds * 1000L); markNow() }
            else -> {}   // SELECTION_CHANGE handled on dispose; NEVER = manual only
        }
    }
    DisposableEffect(convoId) {
        onDispose {
            if (prefs.mode == MarkReadMode.SELECTION_CHANGE && unread && !marked) {
                NotificationHelper.removeDelivered(ctx, listOf(convoId))
                scope.launch { act() }
            }
        }
    }
}
