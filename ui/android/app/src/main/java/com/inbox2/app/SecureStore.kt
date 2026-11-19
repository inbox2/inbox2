package com.inbox2.app

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Keystore-backed encrypted secret store — the Android counterpart to the iOS Keychain.
 * Every app secret (the inbox2 mx session token, the `ink_` personal API key, the OpenAI
 * key, the HuggingFace token, the TypeSafe key) lives here, encrypted at rest with an AES-256 master key
 * held in the Android Keystore (hardware-backed where available).
 *
 * The non-secret prefs (lane choices, the proxy-enabled toggle, the OpenAI voice, the
 * mark-read mode) stay in their ordinary SharedPreferences files — only secrets move here.
 */
object SecureStore {
    const val MX_TOKEN = "mx_token"
    const val INK_API_KEY = "ink_api_key"
    const val OPENAI_KEY = "openai_key"
    const val HF_TOKEN = "hf_token"
    /** The user's own TypeSafe (Jev) key for local-channel triage (docs/Triage.md). */
    const val TYPESAFE_KEY = "typesafe_api_key"

    @Volatile private var cached: SharedPreferences? = null

    fun prefs(context: Context): SharedPreferences {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            val ctx = context.applicationContext
            val p = runCatching {
                val masterKey = MasterKey.Builder(ctx)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
                EncryptedSharedPreferences.create(
                    ctx, "inbox2_secure", masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                )
            }.getOrElse {
                // Keystore key invalidated (e.g. lock-screen change) — reset the store so
                // the user re-auths rather than crashing on every read.
                Log.w("inbox2.secure", "secure store unreadable, resetting: ${it.message}")
                ctx.deleteSharedPreferences("inbox2_secure")
                val masterKey = MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
                EncryptedSharedPreferences.create(
                    ctx, "inbox2_secure", masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                )
            }
            cached = p
            return p
        }
    }

    fun get(context: Context, key: String): String? =
        prefs(context).getString(key, null)?.takeIf { it.isNotEmpty() }

    fun set(context: Context, key: String, value: String?) {
        prefs(context).edit().apply { if (value.isNullOrEmpty()) remove(key) else putString(key, value) }.apply()
    }
}
