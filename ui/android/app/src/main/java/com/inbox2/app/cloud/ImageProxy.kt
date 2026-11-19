package com.inbox2.app.cloud

import android.content.Context
import android.util.Base64
import com.inbox2.app.AppConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Privacy store + server-side image proxy — the Android counterpart to the iOS
 * PrivacyStore/ImageProxy (Keychain.swift). Remote images in mail are fetched through
 * the Rails backend so the sender never sees the reader's IP, device, or open-time
 * (tracking-pixel defence). The bearer is the personal API key (`ink_…`) when set,
 * else the signed-in inbox2 mx session token — the same dual-source model the desktop
 * `image_proxy_controller` accepts. Images come back as `data:` URIs so the WebView
 * keeps a strict CSP (`data: blob:`, never `https:`).
 *
 * The API key lives in `SecureStore` (EncryptedSharedPreferences over an Android
 * Keystore master key), like CloudSession's token; only the toggle is a plain pref.
 */
class PrivacyStore(context: Context) {
    private val appCtx = context.applicationContext
    // Non-secret toggle stays in ordinary prefs; the API key lives in SecureStore.
    private val sp = appCtx.getSharedPreferences("inbox2_privacy", Context.MODE_PRIVATE)

    /** The personal API key (`ink_…`), or null. */
    val apiKey: String? get() = com.inbox2.app.SecureStore.get(appCtx, com.inbox2.app.SecureStore.INK_API_KEY)

    /** Whether requested remote images load privately through the proxy. Default on. */
    var proxyEnabled: Boolean
        get() = sp.getBoolean(KEY_PROXY, true)
        set(v) { sp.edit().putBoolean(KEY_PROXY, v).apply() }

    /** Validate (must be an `ink_` key) + persist. Returns false if malformed. */
    fun saveApiKey(value: String): Boolean {
        val v = value.trim()
        if (!v.startsWith(API_KEY_PREFIX)) return false
        com.inbox2.app.SecureStore.set(appCtx, com.inbox2.app.SecureStore.INK_API_KEY, v)
        return true
    }

    fun clearApiKey() { com.inbox2.app.SecureStore.set(appCtx, com.inbox2.app.SecureStore.INK_API_KEY, null) }

    /** The bearer to authenticate the proxy: the personal API key if present, else the
     *  mx session token. Null when neither is available (images then stay blocked). */
    fun bearer(): String? = apiKey ?: com.inbox2.app.SecureStore.get(appCtx, com.inbox2.app.SecureStore.MX_TOKEN)

    /** Whether a proxy bearer is available at all (drives the reader's image policy). */
    fun hasBearer(): Boolean = bearer() != null

    companion object {
        const val API_KEY_PREFIX = "ink_"
        private const val KEY_PROXY = "image_proxy_enabled"
    }
}

object ImageProxy {
    /** Fetch a remote image server-side and return it as a base64 `data:` URI. A data
     *  URI keeps the reader's CSP at `data: blob:` (no `https:`), so nothing loads
     *  cross-origin even after the swap. Null on any failure (missing bearer, non-2xx,
     *  transport) — the placeholder simply stays. */
    suspend fun fetchDataURI(rawURL: String, bearer: String?): String? =
        fetch(rawURL, bearer)?.let { (ct, bytes) -> "data:$ct;base64,${Base64.encodeToString(bytes, Base64.NO_WRAP)}" }

    /** Raw proxied bytes + content type (a notification's site icon decodes these).
     *  Null on any failure, same as [fetchDataURI]. */
    suspend fun fetch(rawURL: String, bearer: String?, timeoutMs: Int = 0): Pair<String, ByteArray>? = withContext(Dispatchers.IO) {
        if (bearer.isNullOrEmpty()) return@withContext null
        runCatching {
            val encoded = URLEncoder.encode(rawURL, "UTF-8")
            val c = (URL("${AppConfig.apiBase}/image-proxy?url=$encoded").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                instanceFollowRedirects = false   // never replay the bearer across a redirect
                setRequestProperty("Authorization", "Bearer $bearer")
                connectTimeout = timeoutMs   // 0 = no limit (the reader's default)
                readTimeout = timeoutMs
            }
            if (c.responseCode !in 200..299) return@runCatching null
            val ct = (c.contentType ?: "image/png").substringBefore(";").trim().ifEmpty { "image/png" }
            ct to c.inputStream.use { it.readBytes() }
        }.getOrNull()
    }

    /** Consented direct fetch — graceful degradation for hosts the proxy can't reach.
     *  Some image CDNs sit behind bot management (Cloudflare etc.) that 403s any
     *  server-side client by TLS fingerprint, while real devices pass. After an
     *  explicit "Load directly" tap, the failed image is fetched straight from the
     *  device — revealing the reader's IP to that host only — and returned as a
     *  `data:` URI so the WebView CSP stays strict (`data: blob:`, never `https:`). */
    suspend fun fetchDirectDataURI(rawURL: String): String? = withContext(Dispatchers.IO) {
        runCatching {
            val c = (URL(rawURL).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Accept", "image/*")
            }
            if (c.responseCode !in 200..299) return@runCatching null
            val ct = (c.contentType ?: "").substringBefore(";").trim()
            if (!ct.startsWith("image/")) return@runCatching null
            val bytes = c.inputStream.use { it.readBytes() }
            "data:$ct;base64,${Base64.encodeToString(bytes, Base64.NO_WRAP)}"
        }.getOrNull()
    }
}

/**
 * Sender pictures from `GET /api/v1/avatars` (Gravatar, else the sender domain's
 * icon — resolved and fetched server-side, so the phone never contacts either);
 * the iOS `AvatarImages`. Null means "draw initials". Decoded at avatar size into
 * an LRU; only a picture or a confirmed 404 is cached, so a network blip retries.
 */
object AvatarImages {
    private const val PIXELS = 160
    /** A confirmed 404; re-asked after an hour. */
    private class Miss(val at: Long = System.currentTimeMillis())
    private val cache = android.util.LruCache<String, Any>(400)
    private val inFlight = java.util.concurrent.ConcurrentHashMap<String, kotlinx.coroutines.Deferred<Any?>>()
    private val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + Dispatchers.IO)

    suspend fun get(context: Context, raw: String): android.graphics.Bitmap? {
        val email = raw.trim().lowercase()
        if ('@' !in email) return null
        // Not cached without a bearer: signing in later should still load it.
        // The signed-in session first — the token every other API call uses; a stale
        // personal `ink_` key 401'd every avatar (2026-11-19, iPad).
        val bearer = com.inbox2.app.SecureStore.get(context.applicationContext, com.inbox2.app.SecureStore.MX_TOKEN)
            ?: PrivacyStore(context).bearer() ?: return null
        when (val hit = cache.get(email)) {
            is android.graphics.Bitmap -> return hit
            is Miss -> if (System.currentTimeMillis() - hit.at < 3_600_000) return null
        }
        val answer = inFlight.getOrPut(email) { scope.async { fetch(email, bearer) } }.await()
        inFlight.remove(email)
        if (answer != null) cache.put(email, answer)   // null = transient, retry next time
        return answer as? android.graphics.Bitmap
    }

    /** A Bitmap, [Miss] for a confirmed 404, or null for a failure worth retrying. */
    private fun fetch(email: String, bearer: String): Any? = runCatching {
        val c = (URL("${AppConfig.apiBase}/avatars?email=${URLEncoder.encode(email, "UTF-8")}").openConnection() as HttpURLConnection).apply {
            instanceFollowRedirects = false   // never replay the bearer across a redirect
            setRequestProperty("Authorization", "Bearer $bearer")
            connectTimeout = 5000
            readTimeout = 5000
        }
        try {
            when (c.responseCode) {
                404 -> Miss()
                200 -> downsample(c.inputStream.use { it.readBytes() }) ?: Miss()
                else -> null
            }
        } finally {
            c.errorStream?.close()
            c.disconnect()
        }
    }.getOrNull()

    /** Decode at avatar size — a big domain icon never lands full-size in memory. */
    private fun downsample(bytes: ByteArray): android.graphics.Bitmap? {
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= PIXELS) sample *= 2
        return android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size,
            android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })
    }
}
