package com.inbox2.app.fcm

import android.content.Context
import android.os.Build
import android.util.Log
import com.inbox2.app.SecureStore
import com.inbox2.app.cloud.CloudClient
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Keeps the device's FCM token registered with the API (docs/Cloud-Push.md "Mobile
 * push"). Registration is an idempotent upsert keyed on the token, so calling this on
 * every launch and on FCM token rotation is safe. Auth is the same bearer the rest of
 * the cloud client uses (mx session token, else the personal API key) — without one
 * the API has no user to attach the device to, so we skip and retry next launch.
 */
object FcmTokenManager {
    private const val TAG = "FcmTokenManager"
    private const val LAST_REGISTERED = "fcm_last_registered_token"

    private val scope = CoroutineScope(Dispatchers.IO)

    /** Fetch the current FCM token and register it if it changed (or never registered). */
    fun ensureRegistered(context: Context) {
        val appContext = context.applicationContext
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token -> register(appContext, token) }
            .addOnFailureListener { Log.w(TAG, "FCM token fetch failed: ${it.message}") }
    }

    /** Register a known token (FirebaseMessagingService.onNewToken hands it in directly). */
    fun register(context: Context, token: String) {
        if (token.isBlank()) return
        // Whole body on IO: callers land on the main thread (Task listener,
        // onNewToken) and the SecureStore reads hit the keystore.
        scope.launch {
            if (SecureStore.get(context, LAST_REGISTERED) == token) return@launch
            val bearer = SecureStore.get(context, SecureStore.MX_TOKEN)
                ?: SecureStore.get(context, SecureStore.INK_API_KEY)
            if (bearer == null) {
                Log.i(TAG, "no API bearer yet — push registration deferred")
                return@launch
            }
            runCatching {
                val client = CloudClient().apply { setToken(bearer) }
                client.registerPushDevice(token, deviceName())
                SecureStore.set(context, LAST_REGISTERED, token)
                Log.i(TAG, "registered FCM token with the API")
            }.onFailure { Log.w(TAG, "push registration failed: ${it.message}") }
        }
    }

    /** Drop the registered-token marker (sign-out) so the next launch re-registers. */
    fun forget(context: Context) {
        SecureStore.set(context, LAST_REGISTERED, null)
    }

    private fun deviceName(): String =
        "${Build.MANUFACTURER} ${Build.MODEL}".trim().ifEmpty { "Android" }
}
